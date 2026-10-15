import dataclasses
import gzip
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from curbside import pipeline

CSV = b'"Summons Number","Plate ID"\n"4,966,660,087","KET9602"\n'


def serve(encoding):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            body = gzip.compress(CSV) if encoding == "gzip" else CSV
            self.send_response(200)
            self.send_header("Content-Type", "text/csv")
            if encoding == "gzip":
                self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


@pytest.mark.parametrize("encoding", ["gzip", "identity"])
@pytest.mark.parametrize("gzipped", [True, False])
def test_fetch_writes_the_expected_bytes(tmp_path, encoding, gzipped):
    server = serve(encoding)
    try:
        target = tmp_path / ("out.csv.gz" if gzipped else "out.csv")
        pipeline.fetch(f"http://127.0.0.1:{server.server_port}/x", target, gzipped)
    finally:
        server.shutdown()
    data = target.read_bytes()
    assert (gzip.decompress(data) if gzipped else data) == CSV
    assert not target.with_name(target.name + ".part").exists()


def test_download_skips_files_that_exist(cfg, tmp_path, capsys):
    local = dataclasses.replace(cfg, data_dir=tmp_path)
    local.codes_file.write_bytes(CSV)
    local.violations_file.write_bytes(gzip.compress(CSV))
    pipeline.download(local)
    assert capsys.readouterr().out.count("already there") == 2
