import os
import vapoursynth as vs

core = vs.core

def load(path: str):
    try:
        core.std.LoadPlugin(path=path)
    except vs.Error as e:
        if "already loaded" not in str(e):
            raise

# Explicit plugin loads (since autoload has been unreliable)
load("/usr/lib/x86_64-linux-gnu/vapoursynth/libvivtc.so")
load("/home/ryan/.local/share/vsrepo/plugins/libffms2.so")

SRC = os.environ["VS_INPUT"]
TFF = int(os.environ.get("VS_TFF", "1"))

clip = core.ffms2.Source(source=SRC)

# VFM: field matching — reconstructs progressive frames from interlaced fields
clip = core.vivtc.VFM(clip, order=TFF)

# VDecimate: removes the duplicate frame from each 5-frame telecine group (30fps → 24fps)
clip = core.vivtc.VDecimate(clip)

clip.set_output()
