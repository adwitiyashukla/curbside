import argparse
import sys

from curbside import bench, config, erd, pipeline


def main(argv=None):
    parser = argparse.ArgumentParser(prog="curbside")
    parser.add_argument("--config", default="config.toml")
    sub = parser.add_subparsers(dest="command", required=True)
    download = sub.add_parser("download", help="fetch the parking tickets and the code list")
    download.add_argument("--force", action="store_true")
    sub.add_parser("load", help="copy the raw files into the raw schema")
    build = sub.add_parser("build", help="clean, normalize, index and check")
    build.add_argument("--from", dest="start", choices=pipeline.BUILD_FILES, help="resume from this step")
    sub.add_parser("bench", help="time the benchmark queries")
    sub.add_parser("erd", help="print the schema as a mermaid diagram")
    args = parser.parse_args(argv)

    try:
        cfg = config.load(args.config)
    except config.ConfigError as e:
        print(f"config error: {e}", file=sys.stderr)
        return 2

    if args.command == "download":
        pipeline.download(cfg, force=args.force)
    elif args.command == "load":
        pipeline.load(cfg)
    elif args.command == "build":
        pipeline.build(cfg, start=args.start)
    elif args.command == "bench":
        bench.run(cfg)
    elif args.command == "erd":
        print(erd.render(cfg))
    return 0


if __name__ == "__main__":
    sys.exit(main())
