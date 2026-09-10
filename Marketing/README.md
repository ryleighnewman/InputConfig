# InputConfig marketing

Two commands, run from this directory:

```bash
tools/shoot_all.sh          # capture every screen into shots/
python3 tools/posters13.py  # composite -> ~/Desktop/InputConfig Posters 1.3
```

`README-PIPELINE.md` is the reference: what each step does, why the corners are
cut the way they are, and the traps that have cost time before. Read it before
changing either script.

Ten posters at 2880x1800 are written to `~/Desktop/InputConfig Posters 1.3`.
They are not kept in the repo - regenerate them, do not archive them, so there
is never a stale set to pick from by mistake.

Four shots have no debug hook and are captured by hand. Do not delete them:

* `editor-scan.png` - the scan overlay counting down
* `options-full-live.png` - one binding row with every option open
* `viz-controller.png`, `viz-midi.png` - the live visualizer, controller and MIDI

Everything else in `shots/` is produced by `tools/shoot_all.sh`.
