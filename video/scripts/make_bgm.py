"""Copipe 紹介動画の BGM をプログラムで作る（著作権の心配がない自作の曲）

120 BPM・イ短調のエレクトロ。動画の流れに合わせて
  0〜4 秒   : こもった和音とせり上がる音（ライザー）、スネアの連打でためる
  4 秒      : ドロップ（低い「ドン」とシンバル）。ここから全部の楽器が入る
  4〜68 秒  : キック・クラップ・ハイハット・ベース・きらきらしたアルペジオ。16 秒ごとに盛り上げを変える
  68〜70 秒 : 次のドロップに向けてためる
  70 秒〜   : 大きな和音を響かせて終わる
使い方: python3 scripts/make_bgm.py public/bgm.wav 78
（書き出したあと、ffmpeg で音の大きさを -14 LUFS にそろえる）
"""
import os
import subprocess
import sys
import wave

import numpy as np
from scipy.signal import butter, fftconvolve, sosfilt

RATE = 44100
BPM = 120
BEAT = 60 / BPM          # 0.5 秒
BAR = BEAT * 4           # 2 秒
DROP = 2 * BAR           # 4 秒
OUTRO = 35 * BAR         # 70 秒
# 動画の場面が切り替わる秒（どれも小節の頭。ここに短いライザーと「ドン」を入れる）
SCENES = [14, 24, 32, 42, 52, 60]

out_path = sys.argv[1] if len(sys.argv) > 1 else "public/bgm.wav"
duration = float(sys.argv[2]) if len(sys.argv) > 2 else 78.0
n = int(RATE * duration)
rng = np.random.default_rng(3)

# 楽器ごとのトラック（左右）と、残響に送るトラック
bus = {name: np.zeros((2, n)) for name in ["drums", "bass", "pad", "lead", "fx"]}
send = np.zeros((2, n))


def midi(note):
    return 440.0 * 2 ** ((note - 69) / 12)


def times(length):
    return np.arange(int(length * RATE)) / RATE


def filt(x, cutoff, kind="low", order=2):
    sos = butter(order, cutoff, kind, fs=RATE, output="sos")
    return sosfilt(sos, x)


def add(name, signal, start, pan=0.0, gain=1.0, reverb=0.0):
    i = int(start * RATE)
    if i >= n or i + len(signal) <= 0:
        return
    s = signal[: n - i] * gain
    lgain, rgain = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
    bus[name][0, i:i + len(s)] += s * lgain
    bus[name][1, i:i + len(s)] += s * rgain
    if reverb:
        send[0, i:i + len(s)] += s * lgain * reverb
        send[1, i:i + len(s)] += s * rgain * reverb


def saw(freq, length, phase=0.0):
    t = times(length)
    return 2 * ((freq * t + phase) % 1.0) - 1


def supersaw(freq, length, voices=7, spread=0.014):
    out = np.zeros(int(length * RATE))
    for v in range(voices):
        detune = 1 + spread * (v - (voices - 1) / 2) / ((voices - 1) / 2)
        out += saw(freq * detune, length, rng.random())
    return out / voices


def adsr(length, a, d, s, r):
    t = times(length)
    env = np.where(t < a, t / max(a, 1e-4), s + (1 - s) * np.exp(-(t - a) / max(d, 1e-4)))
    return env * np.clip((length - t) / max(r, 1e-4), 0, 1)


# コード進行（1 小節ずつ）: Am - F - C - G
chords = [
    ([57, 64, 69, 72, 76], 33),  # Am
    ([53, 60, 65, 69, 72], 29),  # F
    ([55, 60, 64, 67, 72], 36),  # C
    ([55, 59, 62, 67, 71], 31),  # G
]
bars = int(duration / BAR) + 1

# ---- ドラム ----


def kick():
    t = times(0.45)
    freq = 48 + 110 * np.exp(-t * 28)
    body = np.sin(2 * np.pi * np.cumsum(freq) / RATE) * np.exp(-t * 7.5)
    click = filt(rng.standard_normal(len(t)), 2500, "high") * np.exp(-t * 300) * 0.4
    return np.tanh((body + click) * 1.6)


def clap():
    t = times(0.35)
    noise = filt(rng.standard_normal(len(t)), [900, 3200], "band")
    env = np.zeros_like(t)
    for k, off in enumerate([0, 0.011, 0.022]):
        env += np.where(t >= off, np.exp(-(t - off) * (220 if k < 2 else 16)), 0)
    return noise * env * 0.9


def hat(open_=False):
    length = 0.18 if open_ else 0.05
    t = times(length)
    return filt(rng.standard_normal(len(t)), 7500, "high") * np.exp(-t * (18 if open_ else 90))


def snare_roll(start, length, gain=0.5):
    """だんだん細かくなるスネアの連打（ためのところ）"""
    t = start
    while t < start + length:
        progress = (t - start) / length
        step = BEAT / 2 if progress < 0.5 else BEAT / 4 if progress < 0.85 else BEAT / 8
        add("drums", clap(), t, gain=gain * (0.4 + 0.6 * progress), reverb=0.15)
        t += step


KICK, CLAP = kick(), clap()

# ---- 効果音 ----


def riser(length):
    """せり上がるノイズ（高いほうへ広がっていく）"""
    t = times(length)
    noise = rng.standard_normal(len(t))
    out = np.zeros_like(noise)
    chunks = 40
    size = len(t) // chunks
    for c in range(chunks):
        center = 300 * (8000 / 300) ** (c / chunks)
        seg = slice(c * size, (c + 1) * size if c < chunks - 1 else len(t))
        out[seg] = filt(noise[seg], [center * 0.7, min(center * 1.4, 18000)], "band")
    return out * (t / length) ** 2


def impact():
    t = times(2.2)
    boom = np.sin(2 * np.pi * np.cumsum(40 + 50 * np.exp(-t * 6)) / RATE) * np.exp(-t * 2.2)
    crash = filt(rng.standard_normal(len(t)), 3500, "high") * np.exp(-t * 1.8) * 0.35
    return boom + crash


# ---- 曲を組み立てる ----

for bar in range(bars):
    start = bar * BAR
    notes, root = chords[bar % 4]
    in_groove = DROP <= start < OUTRO - BAR
    # 盛り上げの段階: 0 = 最初の場面、1 = 2 つ目の場面から、2 = 後半（整えて貼り付けの場面から）
    section = -1 if start < DROP else 0 if start < SCENES[0] else 1 if start < SCENES[3] else 2

    # パッド（はじめはこもった音、ドロップから明るく）
    for note in notes[:4]:
        pad = supersaw(midi(note), BAR + 0.3) * adsr(BAR + 0.3, 0.25 if start < DROP else 0.02, 0.6, 0.8, 0.25)
        cutoff = 500 + 1500 * bar if start < DROP else (5200 if start < OUTRO else 3800)
        add("pad", filt(pad, cutoff), start, pan=(note % 7 - 3) * 0.12, gain=0.09, reverb=0.35)

    if in_groove or OUTRO - BAR <= start < OUTRO:
        # ドラム
        for beat in range(4):
            t0 = start + beat * BEAT
            fill = in_groove and (start + BAR) in SCENES and beat >= 2  # 場面が変わる前のおかず
            add("drums", KICK, t0, gain=0.95)
            if beat in (1, 3) and not fill:
                add("drums", CLAP, t0, gain=0.55, reverb=0.2)
            for k in range(4):
                velocity = [0.5, 0.25, 0.75, 0.25][k]
                add("drums", hat(), t0 + k * BEAT / 4, pan=0.25, gain=0.16 * velocity)
            if section >= 1:
                add("drums", hat(open_=True), t0 + BEAT / 2, pan=-0.2, gain=0.09)
            if fill:
                for k in range(4):
                    add("drums", CLAP, t0 + k * BEAT / 4, gain=0.25 + 0.08 * k, reverb=0.15)

        # ベース（裏拍を強く。最後の 8 分音符はオクターブ上）
        for k in range(8):
            length = BEAT / 2 * 0.9
            note = root + (12 if k == 7 else 0)
            b = saw(midi(note), length) * 0.6 + np.sin(2 * np.pi * midi(note) * times(length))
            b = filt(b, 700 + 300 * (k % 2)) * adsr(length, 0.004, 0.08, 0.6, 0.03)
            add("bass", b, start + k * BEAT / 2, gain=0.33 if k % 2 else 0.22)

        # アルペジオ（2 つ目の区切りから。3 つ目からは 1 オクターブ上も重ねる）
        if section >= 1 or OUTRO - BAR <= start < OUTRO:
            pattern = [0, 2, 3, 4, 3, 2, 1, 2]
            for k in range(16):
                note = notes[pattern[k % 8]] + 12
                length = 0.22
                env = np.exp(-times(length) * 14)
                pluck = filt(saw(midi(note), length) + 0.5 * saw(midi(note) * 1.005, length), 3800) * env
                add("lead", pluck, start + k * BEAT / 4, pan=0.3 if k % 2 else -0.3, gain=0.11, reverb=0.3)
                if section >= 2:
                    add("lead", filt(saw(midi(note + 12), length), 5000) * env, start + k * BEAT / 4,
                        pan=-0.4 if k % 2 else 0.4, gain=0.05, reverb=0.4)

# ためと、ドロップ
add("fx", riser(DROP), 0, gain=0.35, reverb=0.3)
snare_roll(BAR, BAR, gain=0.45)
add("fx", impact(), DROP, gain=0.9, reverb=0.4)
for at in SCENES:  # 場面が変わるところに軽いライザーと「ドン」
    add("fx", riser(BAR), at - BAR, gain=0.2, reverb=0.3)
    add("fx", impact() * 0.5, at, gain=0.5, reverb=0.3)
add("fx", riser(BAR), OUTRO - BAR, gain=0.35, reverb=0.3)
snare_roll(OUTRO - BAR, BAR, gain=0.4)
add("fx", impact(), OUTRO, gain=0.9, reverb=0.5)
# 終わりの大きな和音
for note in chords[0][0]:
    chord = supersaw(midi(note), duration - OUTRO) * adsr(duration - OUTRO, 0.01, 2.5, 0.35, 3.0)
    add("pad", filt(chord, 4200), OUTRO, pan=(note % 7 - 3) * 0.15, gain=0.1, reverb=0.6)

# ---- 仕上げ ----

# ポンプ感（キックに合わせてパッドとベースを下げる）
t = np.arange(n) / RATE
pump = 1 - 0.75 * np.exp(-((t - DROP) % BEAT) / 0.09)
pump = np.where((t >= DROP) & (t < OUTRO), pump, 1.0)
for name in ["pad", "bass"]:
    bus[name] *= pump

# 残響（ノイズを使ったホールの響き）
ir_t = times(2.6)
ir = np.stack([rng.standard_normal(len(ir_t)), rng.standard_normal(len(ir_t))]) * np.exp(-ir_t * 2.4)
ir[:, : int(0.02 * RATE)] = 0
wet = np.stack([fftconvolve(filt(send[c], 300, "high"), ir[c])[:n] for c in range(2)]) * 0.05

mix = sum(bus.values()) + wet
mix = np.stack([filt(mix[c], 28, "high") for c in range(2)])
mix = np.tanh(mix * 1.4) / np.tanh(1.4)  # 軽く飽和させてまとめる
fade = np.clip(t / 0.05, 0, 1) * np.clip((duration - t) / 4.0, 0, 1)
mix *= fade
mix = mix / np.abs(mix).max() * 0.9

raw_path = out_path + ".raw.wav"
with wave.open(raw_path, "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes((mix.T * 32767).astype("<i2").tobytes())

# 音の大きさを -14 LUFS にそろえる
subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", raw_path,
                "-af", "loudnorm=I=-14:TP=-1.5:LRA=11", "-ar", str(RATE), out_path], check=True)
os.remove(raw_path)
print(f"wrote {out_path} ({duration:.1f}s)")
