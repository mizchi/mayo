const root = new URL("../../dist/web/", import.meta.url);

function contentType(pathname: string): string {
  if (pathname.endsWith(".html")) return "text/html; charset=utf-8";
  if (pathname.endsWith(".js")) return "text/javascript; charset=utf-8";
  return "application/octet-stream";
}

Deno.serve({ hostname: "127.0.0.1", port: 4173 }, async (request) => {
  const requestUrl = new URL(request.url);
  const pathname = requestUrl.pathname === "/" ? "index.html" : requestUrl.pathname.slice(1);
  if (pathname.includes("..")) return new Response("Not found", { status: 404 });

  try {
    const body = await Deno.readFile(new URL(pathname, root));
    return new Response(body, {
      headers: {
        "Content-Type": contentType(pathname),
        "Cross-Origin-Opener-Policy": "same-origin",
        "Cross-Origin-Embedder-Policy": "require-corp",
        "Cross-Origin-Resource-Policy": "same-origin",
      },
    });
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return new Response("Not found", { status: 404 });
    throw error;
  }
});
