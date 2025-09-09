import sys
from urllib.parse import urlparse

from git_remote_dropbox.rclone_helper import RcloneHelper
from git_remote_dropbox.util import stdout_to_binary, Level


def main() -> None:
    """Entry point for the rclone-backed helper.

    Accepts URLs of the form: rclone://remote_name/path/to/repo
    """
    stdout_to_binary()
    url = sys.argv[2]
    parsed = urlparse(url)
    if parsed.scheme != "rclone":
        # be tolerant and print an error similar to get_helper
        sys.stderr.write('error: URL must start with the "rclone://" scheme\n')
        sys.exit(1)
    if not parsed.netloc:
        sys.stderr.write('error: rclone URL must be of the form "rclone://remote_name/path"\n')
        sys.exit(1)
    remote = parsed.netloc
    path = parsed.path
    helper = RcloneHelper(remote, path)
    try:
        helper.run()
    except Exception:
        if helper.verbosity >= Level.DEBUG:
            raise
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(1)
