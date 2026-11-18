"""Run a command in a virtual terminal and save screen snapshots as HTML.

Usage: capture.py SCRIPT "ARGS" "T1,T2,..." OUT_PREFIX ["SECS=KEYS,..."]
  Runs `bash SCRIPT ARGS` in a 96x34 pseudo-terminal, emulated with pyte, and
  writes OUT_PREFIX-<T>.html at each time T (seconds), plus OUT_PREFIX-end.html
  when the program exits. Optional key presses are sent at given times.
Environment:
  CAPTURE_TERM   TERM for the program (default xterm-256color; "linux" = TTY)
  CAPTURE_TITLE  window title text (default "kitty — ./install-umbrinoc.sh")
  CAPTURE_BG     terminal background colour (default #1e1e2e; #000 for a TTY)
Named ANSI colours are rendered with the Linux console's VGA palette.
Requires: pip install pyte
"""
import os, pty, select, sys, time, html
import pyte

COLS, ROWS = 96, 34
TITLE = os.environ.get("CAPTURE_TITLE", "kitty — ./install-umbrinoc.sh")
BG = os.environ.get("CAPTURE_BG", "#1e1e2e")
script, args, shots, outprefix = sys.argv[1], sys.argv[2].split(), sys.argv[3].split(","), sys.argv[4]
keys = dict(k.split("=") for k in (sys.argv[5].split(",") if len(sys.argv) > 5 and sys.argv[5] else []))

screen = pyte.Screen(COLS, ROWS)
stream = pyte.ByteStream(screen)
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM=os.environ.get("CAPTURE_TERM","xterm-256color"), COLUMNS=str(COLS), LINES=str(ROWS), TMPDIR="/tmp")
    import fcntl, termios, struct
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    os.execvp("bash", ["bash", script, *args])

def to_html(name):
    out = []
    for y in range(ROWS):
        row = screen.buffer[y]
        line = []
        for x in range(COLS):
            ch = row[x]
            # Linux console VGA palette for named colours (bold = bright).
            vga = {"black": ("000000", "555555"), "red": ("aa0000", "ff5555"), "green": ("00aa00", "55ff55"),
                   "brown": ("aa5500", "ffff55"), "yellow": ("aa5500", "ffff55"), "blue": ("0000aa", "5555ff"),
                   "magenta": ("aa00aa", "ff55ff"), "cyan": ("00aaaa", "55ffff"), "white": ("aaaaaa", "ffffff"),
                   "default": ("aaaaaa", "ffffff")}
            fg = ch.fg
            if fg in vga:
                fg = vga[fg][1 if ch.bold else 0]
            elif not (len(fg) == 6 and all(c in "0123456789abcdef" for c in fg.lower())):
                fg = "aaaaaa"
            style = f"color:#{fg};" + ("font-weight:bold;" if ch.bold else "")
            line.append(f'<span style="{style}">{html.escape(ch.data or " ")}</span>')
        out.append("".join(line))
    body = "\n".join(out)
    open(f"{outprefix}-{name}.html", "w").write(f"""<!doctype html><meta charset=utf-8>
<style>body{{margin:0;background:#11111b}}
.win{{margin:24px;display:inline-block;border-radius:12px;overflow:hidden;box-shadow:0 10px 40px #0008;background:#1e1e2e}}
.bar{{height:30px;background:#181825;display:flex;align-items:center;gap:8px;padding:0 12px;color:#7f849c;font:13px sans-serif}}
.d{{width:12px;height:12px;border-radius:50%}}
pre{{margin:0;padding:14px 18px;font:15px/1.25 'DejaVu Sans Mono','Noto Sans Mono',monospace;color:#cdd6f4;background:{BG}}}</style>
<div class=win><div class=bar><span class=d style=background:#f38ba8></span><span class=d style=background:#f9e2af></span><span class=d style=background:#a6e3a1></span>&nbsp; {html.escape(TITLE)}</div><pre>{body}</pre></div>""")

start = time.time()
pending = [(float(t), t) for t in shots]
sent = set()
while True:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            to_html("end"); break
        if not data:
            to_html("end"); break
        stream.feed(data)
    now = time.time() - start
    for k, v in keys.items():
        if now >= float(k) and k not in sent:
            os.write(fd, v.encode()); sent.add(k)
    while pending and now >= pending[0][0]:
        to_html(pending.pop(0)[1])
    if not pending and not [k for k in keys if k not in sent]:
        break
try:
    os.kill(pid, 9)
except Exception:
    pass
