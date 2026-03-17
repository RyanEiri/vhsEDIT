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

clip = core.ffms2.Source(source=SRC)

# VDecimate: removes duplicate frames from progressive content.
# Used after QTGMC to drop duplicates re-introduced during deinterlacing
# of telecined material (30fps → 24fps).
clip = core.vivtc.VDecimate(clip)

clip.set_output()
