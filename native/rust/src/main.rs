use rayon::prelude::*;
use std::cell::UnsafeCell;
use std::env;
use std::hint::black_box;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Instant;

const MULTIPLIER: u32 = 1_664_525;
const INCREMENT: u32 = 1_013_904_223;

#[inline]
fn mix_value(mut value: u32, rounds: u32) -> u32 {
    for _ in 0..rounds {
        value = value.wrapping_mul(MULTIPLIER).wrapping_add(INCREMENT);
    }
    value
}

fn initial_value(index: usize) -> u32 {
    (index as u32)
        .wrapping_mul(2_654_435_761)
        .wrapping_add(12_345)
}

struct SharedData {
    cells: Box<[UnsafeCell<u32>]>,
}

// Every worker receives a permanently disjoint range for each batch. The main
// thread only reads or initializes cells while all workers are at the barrier.
unsafe impl Sync for SharedData {}

impl SharedData {
    fn new(len: usize) -> Self {
        Self {
            cells: (0..len).map(|_| UnsafeCell::new(0)).collect(),
        }
    }

    fn initialize(&self, elements: usize) {
        for index in 0..elements {
            // SAFETY: initialization occurs between completed batches.
            unsafe { *self.cells[index].get() = initial_value(index) };
        }
    }

    fn transform(&self, start: usize, end: usize, rounds: u32) {
        for index in start..end {
            // SAFETY: ranges assigned to workers never overlap.
            unsafe {
                let cell = self.cells[index].get();
                *cell = mix_value(*cell, rounds);
            }
        }
    }

    fn checksum(&self, elements: usize) -> u32 {
        (0..elements).fold(0, |checksum, index| {
            // SAFETY: checksum is calculated after a completed batch.
            checksum ^ unsafe { *self.cells[index].get() }
        })
    }

    fn values(&self, elements: usize) -> Vec<u32> {
        (0..elements)
            .map(|index| {
                // SAFETY: called after a completed batch.
                unsafe { *self.cells[index].get() }
            })
            .collect()
    }
}

#[derive(Default)]
struct JobState {
    epoch: u64,
    remaining: usize,
    elements: usize,
    compute_rounds: u32,
    stop: bool,
}

struct Control {
    state: Mutex<JobState>,
    start: Condvar,
    done: Condvar,
}

struct StdPool {
    data: Arc<SharedData>,
    control: Arc<Control>,
    workers: Vec<JoinHandle<()>>,
    worker_count: usize,
}

impl StdPool {
    fn new(worker_count: usize, max_elements: usize) -> Self {
        let data = Arc::new(SharedData::new(max_elements));
        let control = Arc::new(Control {
            state: Mutex::new(JobState::default()),
            start: Condvar::new(),
            done: Condvar::new(),
        });
        let workers = (0..worker_count)
            .map(|id| {
                let data = Arc::clone(&data);
                let control = Arc::clone(&control);
                thread::spawn(move || {
                    let mut seen_epoch = 0;
                    loop {
                        let mut state = control.state.lock().expect("job mutex poisoned");
                        while !state.stop && state.epoch == seen_epoch {
                            state = control.start.wait(state).expect("job mutex poisoned");
                        }
                        if state.stop {
                            break;
                        }
                        seen_epoch = state.epoch;
                        let elements = state.elements;
                        let compute_rounds = state.compute_rounds;
                        drop(state);

                        let start = elements * id / worker_count;
                        let end = elements * (id + 1) / worker_count;
                        data.transform(start, end, compute_rounds);

                        let mut state = control.state.lock().expect("job mutex poisoned");
                        state.remaining -= 1;
                        if state.remaining == 0 {
                            control.done.notify_one();
                        }
                    }
                })
            })
            .collect();
        Self {
            data,
            control,
            workers,
            worker_count,
        }
    }
}

trait BenchPool {
    fn run(&mut self, elements: usize, compute_rounds: u32);
    fn initialize(&mut self, elements: usize);
    fn checksum(&self, elements: usize) -> u32;
    fn values(&self, elements: usize) -> Vec<u32>;
}

impl BenchPool for StdPool {
    fn run(&mut self, elements: usize, compute_rounds: u32) {
        let mut state = self.control.state.lock().expect("job mutex poisoned");
        state.elements = elements;
        state.compute_rounds = compute_rounds;
        state.remaining = self.worker_count;
        state.epoch += 1;
        self.control.start.notify_all();
        while state.remaining != 0 {
            state = self.control.done.wait(state).expect("job mutex poisoned");
        }
    }

    fn initialize(&mut self, elements: usize) {
        self.data.initialize(elements);
    }

    fn checksum(&self, elements: usize) -> u32 {
        self.data.checksum(elements)
    }

    fn values(&self, elements: usize) -> Vec<u32> {
        self.data.values(elements)
    }
}

impl Drop for StdPool {
    fn drop(&mut self) {
        {
            let mut state = self.control.state.lock().expect("job mutex poisoned");
            state.stop = true;
            state.epoch += 1;
            self.control.start.notify_all();
        }
        for worker in self.workers.drain(..) {
            worker.join().expect("worker panicked");
        }
    }
}

struct RayonPool {
    pool: rayon::ThreadPool,
    data: Vec<u32>,
    worker_count: usize,
}

impl RayonPool {
    fn new(worker_count: usize, max_elements: usize) -> Self {
        Self {
            pool: rayon::ThreadPoolBuilder::new()
                .num_threads(worker_count)
                .build()
                .expect("failed to build Rayon pool"),
            data: vec![0; max_elements],
            worker_count,
        }
    }
}

impl BenchPool for RayonPool {
    fn run(&mut self, elements: usize, compute_rounds: u32) {
        if elements == 0 {
            self.pool.broadcast(|_| black_box(()));
            return;
        }
        let chunk_size = elements.div_ceil(self.worker_count);
        self.pool.install(|| {
            self.data[..elements]
                .par_chunks_mut(chunk_size)
                .for_each(|chunk| {
                    for value in chunk {
                        *value = mix_value(*value, compute_rounds);
                    }
                });
        });
    }

    fn initialize(&mut self, elements: usize) {
        for index in 0..elements {
            self.data[index] = initial_value(index);
        }
    }

    fn checksum(&self, elements: usize) -> u32 {
        self.data[..elements]
            .iter()
            .fold(0, |checksum, value| checksum ^ value)
    }

    fn values(&self, elements: usize) -> Vec<u32> {
        self.data[..elements].to_vec()
    }
}

#[derive(Clone, Copy)]
struct Summary {
    median_us: f64,
    p95_us: f64,
}

struct ScenarioResult {
    timing: Summary,
    checksum: u32,
}

fn percentile(sorted: &[f64], ratio: f64) -> f64 {
    if sorted.len() == 1 {
        return sorted[0];
    }
    let position = (sorted.len() - 1) as f64 * ratio;
    let lower = position.floor() as usize;
    let upper = position.ceil() as usize;
    let weight = position - lower as f64;
    sorted[lower] * (1.0 - weight) + sorted[upper] * weight
}

fn summarize(mut samples: Vec<f64>) -> Summary {
    samples.sort_by(f64::total_cmp);
    Summary {
        median_us: percentile(&samples, 0.5),
        p95_us: percentile(&samples, 0.95),
    }
}

fn measure_scenario<P: BenchPool + ?Sized>(
    pool: &mut P,
    elements: usize,
    compute_rounds: u32,
    warmups: usize,
    batches: usize,
) -> ScenarioResult {
    pool.initialize(elements);
    for _ in 0..warmups {
        pool.run(elements, compute_rounds);
    }
    let mut samples = Vec::with_capacity(batches);
    for _ in 0..batches {
        let started = Instant::now();
        pool.run(elements, compute_rounds);
        samples.push(started.elapsed().as_secs_f64() * 1_000_000.0);
    }
    ScenarioResult {
        timing: summarize(samples),
        checksum: pool.checksum(elements),
    }
}

#[derive(Clone, Copy)]
enum Backend {
    Std,
    Rayon,
}

fn create_pool(backend: Backend, worker_count: usize, max_elements: usize) -> Box<dyn BenchPool> {
    match backend {
        Backend::Std => Box::new(StdPool::new(worker_count, max_elements)),
        Backend::Rayon => Box::new(RayonPool::new(worker_count, max_elements)),
    }
}

fn backend_name(backend: Backend) -> &'static str {
    match backend {
        Backend::Std => "rust-std",
        Backend::Rayon => "rust-rayon",
    }
}

fn self_test(backend: Backend) {
    let mut pool = create_pool(backend, 3, 17);
    pool.initialize(17);
    let expected: Vec<u32> = (0..17)
        .map(|index| mix_value(initial_value(index), 4))
        .collect();
    pool.run(17, 4);
    assert_eq!(pool.values(17), expected, "transform contract mismatch");
    pool.run(0, 0);
    println!("self-test ok");
}

fn print_scenario(name: &str, result: &ScenarioResult, elements: usize, compute_rounds: u32) {
    let seconds = result.timing.median_us / 1_000_000.0;
    let gib_per_s = if elements == 0 {
        0.0
    } else {
        elements as f64 * 8.0 / seconds / 1_073_741_824.0
    };
    let mops = if compute_rounds == 0 {
        0.0
    } else {
        elements as f64 * compute_rounds as f64 / seconds / 1_000_000.0
    };
    print!(
        "\"{name}\":{{\"elements\":{elements},\"compute_rounds\":{compute_rounds},\"median_us\":{:.3},\"p95_us\":{:.3},\"gib_per_s\":{gib_per_s:.3},\"mops\":{mops:.3},\"checksum\":{}}}",
        result.timing.median_us, result.timing.p95_us, result.checksum
    );
}

fn run_suite(backend: Backend, worker_count: usize, quick: bool) {
    let memory_elements = if quick { 1 << 18 } else { 1 << 22 };
    let memory_batches = if quick { 3 } else { 25 };
    let compute_elements = if quick { 1 << 14 } else { 1 << 18 };
    let compute_rounds = if quick { 16 } else { 64 };
    let compute_batches = if quick { 3 } else { 20 };
    let dispatch_batches = if quick { 100 } else { 5000 };
    let mut pool = create_pool(backend, worker_count, memory_elements);
    let dispatch = measure_scenario(pool.as_mut(), 0, 0, 20, dispatch_batches);
    let memory = measure_scenario(pool.as_mut(), memory_elements, 1, 5, memory_batches);
    let compute = measure_scenario(
        pool.as_mut(),
        compute_elements,
        compute_rounds,
        3,
        compute_batches,
    );
    let name = backend_name(backend);
    print!("{{\"backend\":\"{name}\",\"workers\":{worker_count},");
    print_scenario("dispatch", &dispatch, 0, 0);
    print!(",");
    print_scenario("memory", &memory, memory_elements, 1);
    print!(",");
    print_scenario("compute", &compute, compute_elements, compute_rounds);
    println!("}}");
}

fn run_custom(
    backend: Backend,
    worker_count: usize,
    elements: usize,
    compute_rounds: u32,
    warmups: usize,
    batches: usize,
) {
    let mut pool = create_pool(backend, worker_count, elements);
    let scenario = measure_scenario(pool.as_mut(), elements, compute_rounds, warmups, batches);
    let name = backend_name(backend);
    print!("{{\"backend\":\"{name}\",\"workers\":{worker_count},");
    print_scenario("scenario", &scenario, elements, compute_rounds);
    println!("}}");
}

fn main() {
    let mut backend = Backend::Std;
    let mut workers = 4;
    let mut run_self_test = false;
    let mut quick = false;
    let mut custom_elements = None;
    let mut custom_rounds = 0;
    let mut custom_warmups = 3;
    let mut custom_batches = 10;
    let args: Vec<String> = env::args().skip(1).collect();
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--backend" => {
                index += 1;
                backend = match args.get(index).map(String::as_str) {
                    Some("std") => Backend::Std,
                    Some("rayon") => Backend::Rayon,
                    value => panic!("unknown backend: {value:?}"),
                };
            }
            "--workers" => {
                index += 1;
                workers = args
                    .get(index)
                    .expect("--workers requires a value")
                    .parse()
                    .expect("workers must be a positive integer");
                assert!(workers > 0, "workers must be positive");
            }
            "--self-test" => run_self_test = true,
            "--quick" => quick = true,
            "--elements" => {
                index += 1;
                custom_elements = Some(
                    args.get(index)
                        .expect("--elements requires a value")
                        .parse()
                        .expect("elements must be a non-negative integer"),
                );
            }
            "--rounds" => {
                index += 1;
                custom_rounds = args
                    .get(index)
                    .expect("--rounds requires a value")
                    .parse()
                    .expect("rounds must be a non-negative integer");
            }
            "--warmups" => {
                index += 1;
                custom_warmups = args
                    .get(index)
                    .expect("--warmups requires a value")
                    .parse()
                    .expect("warmups must be a non-negative integer");
            }
            "--batches" => {
                index += 1;
                custom_batches = args
                    .get(index)
                    .expect("--batches requires a value")
                    .parse()
                    .expect("batches must be a positive integer");
                assert!(custom_batches > 0, "batches must be positive");
            }
            argument => panic!("unknown argument: {argument}"),
        }
        index += 1;
    }
    if run_self_test {
        self_test(backend);
    } else if let Some(elements) = custom_elements {
        run_custom(
            backend,
            workers,
            elements,
            custom_rounds,
            custom_warmups,
            custom_batches,
        );
    } else {
        run_suite(backend, workers, quick);
    }
}
