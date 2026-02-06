import vapoursynth as vs
core = vs.core

# Source: Kdenlive export (interlaced)
clip = core.ffms2.Source(source=r"INPUT_EDIT_MASTER.mkv")

# NTSC VHS is TFF
clip = core.std.SetFieldBased(clip, 2)  # 2 = TFF

# QTGMC deinterlace
clip = core.qtgmc.QTGMC(
    clip,
    Preset="Slower",
    TFF=True,
    FPSDivisor=1,   # bob to 59.94p
    InputType=0    # normal interlaced source
)

# Convert to square pixel 4:3 if desired later
clip = core.resize.Bicubic(clip, format=vs.YUV420P8)

clip.set_output()

