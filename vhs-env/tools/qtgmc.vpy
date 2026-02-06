import os
import vapoursynth as vs
import havsfunc as haf

core = vs.core

def load(path: str):
    try:
        core.std.LoadPlugin(path=path)
    except vs.Error as e:
        if "already loaded" not in str(e):
            raise

# Explicit plugin loads (since autoload has been unreliable)
load("/home/ryan/.local/share/vsrepo/plugins/libffms2.so")
load("/home/ryan/.local/share/vsrepo/plugins/libmvtools.so")
load("/home/ryan/.local/share/vsrepo/plugins/libfmtconv.so")
load("/home/ryan/.local/share/vsrepo/plugins/libnnedi3.so")
load("/home/ryan/.local/share/vsrepo/plugins/libmiscfilters.so")

SRC = os.environ["VS_INPUT"]
TFF = int(os.environ.get("VS_TFF", "1"))
FPSDIV = int(os.environ.get("VS_FPSDIV", "2"))
PRESET = os.environ.get("VS_PRESET", "Slower")

clip = core.ffms2.Source(source=SRC)

# No resize/format conversion here (your input is already yuv422p 8-bit)
clip = haf.QTGMC(
    clip,
    Preset=PRESET,
    TFF=TFF,
    FPSDivisor=FPSDIV,
    EdiMode="nnedi3",
)

clip.set_output()

