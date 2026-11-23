#!/usr/bin/env python3
"""Make the babble voice samples in sounds/.

Nothing in sounds/ is recorded: every file is synthesized here, so the set can
be remade, tuned or extended at any time. Run from anywhere:

    python3 tools/make_sounds.py

Needs numpy and an ffmpeg built with libvorbis (Luanti only plays Ogg Vorbis).

How the voice is made (classic formant synthesis):

* A buzzing source: the vocal folds are a band-limited pulse train at the
  pitch (f0) of the voice, with a gentle pitch contour and a little jitter so
  it doesn't sound like a test tone. Whispers use breath (noise) instead.
* A vocal tract: four resonators in cascade, one per formant. Their
  frequencies are what makes an "a" an "a" and an "i" an "i". Each syllable
  glides into its vowel from a consonant-like start (a "b" or a "d"), which is
  what makes a string of blips sound like speech rather than beeps.
* An envelope, a click-free fade at both ends, and loudness normalization so
  every file is equally loud; the mod sets the volume per chat mode.

Sets (all mono, so the engine can place them in 3D):
    talk_<v>1, talk_<v>2   normal speech, "b"-like and "d"-like onsets
    shout_<v>              higher, brighter, longer and a bit rough
    whisper_<v>            breath only, no pitch
    muffled_<v>            talk heard through a wall: low-passed
where <v> is one of a e i o u.

The in-game pitch of each player's voice comes from the `pitch` sound
parameter, which scales these samples up or down.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import wave
import zlib

import numpy as np

SR = 22050
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "sounds"))
PREFIX = "proximity_chat_"

# Formant frequencies (Hz), F1..F4, roughly between adult male and female
# averages, so the in-game pitch shift can push them either way.
VOWELS = {
	"a": (780, 1250, 2550, 3500),
	"e": (500, 1800, 2550, 3500),
	"i": (340, 2200, 2950, 3700),
	"o": (530, 920, 2450, 3400),
	"u": (360, 820, 2300, 3300),
}
BANDWIDTHS = (90, 110, 150, 220)

# Where the formants start before gliding into the vowel: a "b"-like start
# (all formants low, lips closed) and a "d"-like start (F2 near 1800 Hz).
ONSETS = {
	"1": (260, 900, 2250, 3300),
	"2": (280, 1750, 2700, 3500),
}

SCHWA = (500, 1500, 2500, 3500)


def rng_for(name):
	"""Deterministic randomness, so remaking the set gives the same files."""
	return np.random.default_rng(zlib.crc32(name.encode()))


def smoothstep(x):
	x = np.clip(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


def smooth_noise(n, rng, cutoff_hz):
	"""Low-passed noise in [-1, 1]: slow random wobble for pitch jitter."""
	raw = rng.standard_normal(n)
	alpha = 1.0 - np.exp(-2.0 * np.pi * cutoff_hz / SR)
	out = np.empty(n)
	acc = 0.0
	for i in range(n):
		acc += alpha * (raw[i] - acc)
		out[i] = acc
	peak = np.max(np.abs(out)) or 1.0
	return out / peak


def pulse_train(f0, tilt):
	"""Band-limited glottal-ish source: harmonics falling off as 1/k^tilt."""
	phase = 2.0 * np.pi * np.cumsum(f0) / SR
	out = np.zeros(len(f0))
	kmax = int((SR / 2.0 * 0.95) / np.max(f0))
	for k in range(1, kmax + 1):
		out += np.sin(k * phase) / (k ** tilt)
	return out


def resonate(x, freqs, bandwidth):
	"""One Klatt resonator with a time-varying centre frequency."""
	T = 1.0 / SR
	c = -np.exp(-2.0 * np.pi * bandwidth * T)
	r = np.exp(-np.pi * bandwidth * T)
	b = 2.0 * r * np.cos(2.0 * np.pi * freqs * T)
	a = 1.0 - b - c
	y = np.empty(len(x))
	y1 = y2 = 0.0
	for i in range(len(x)):
		yi = a[i] * x[i] + b[i] * y1 + c * y2
		y2 = y1
		y1 = yi
		y[i] = yi
	return y


def vocal_tract(source, start, target, n, glide_s, bw_scale=1.0, f1_scale=1.0):
	"""Run the source through four formants that glide start -> target,
	then relax toward a neutral vowel at the very end."""
	t = np.arange(n) / SR
	dur = n / SR
	glide = smoothstep(t / glide_s)
	relax = smoothstep((t - (dur - 0.025)) / 0.025)
	y = source
	for k in range(4):
		f = start[k] + (target[k] - start[k]) * glide
		f = f + (SCHWA[k] - f) * relax * 0.35
		if k == 0:
			f = f * f1_scale
		y = resonate(y, f, BANDWIDTHS[k] * bw_scale)
	return y


def envelope(n, attack_s, release_s):
	t = np.arange(n) / SR
	dur = n / SR
	att = smoothstep(t / attack_s)
	rel = smoothstep((dur - t) / release_s)
	return att * rel


def biquad_lowpass(x, cutoff, q=0.7071):
	w0 = 2.0 * np.pi * cutoff / SR
	alpha = np.sin(w0) / (2.0 * q)
	cw = np.cos(w0)
	b0 = (1.0 - cw) / 2.0
	b1 = 1.0 - cw
	b2 = (1.0 - cw) / 2.0
	a0 = 1.0 + alpha
	a1 = -2.0 * cw
	a2 = 1.0 - alpha
	b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
	y = np.empty(len(x))
	x1 = x2 = y1 = y2 = 0.0
	for i in range(len(x)):
		xi = x[i]
		yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
		x2, x1 = x1, xi
		y2, y1 = y1, yi
		y[i] = yi
	return y


def pitch_contour(n, f0, rise=0.03, fall=0.07):
	"""A syllable's pitch: up a little early on, then down toward the end."""
	t = np.linspace(0.0, 1.0, n)
	shape = 1.0 + rise * np.sin(np.pi * np.clip(t / 0.6, 0, 1)) - fall * smoothstep((t - 0.4) / 0.6)
	return f0 * shape


def finish(y, n_fade=int(0.003 * SR), rms_db=-18.0, peak_db=-1.0):
	y = y - np.mean(y)
	y[:n_fade] *= np.linspace(0.0, 1.0, n_fade)
	y[-n_fade:] *= np.linspace(1.0, 0.0, n_fade)
	rms = np.sqrt(np.mean(y * y)) or 1.0
	y = y * (10 ** (rms_db / 20.0) / rms)
	peak = np.max(np.abs(y)) or 1.0
	limit = 10 ** (peak_db / 20.0)
	if peak > limit:
		y = y * (limit / peak)
	return y


def talk(vowel, onset, name):
	rng = rng_for(name)
	dur = 0.115 if vowel in "ao" else 0.105
	n = int(dur * SR)
	f0 = pitch_contour(n, 190.0) * (1.0 + 0.012 * smooth_noise(n, rng, 18.0))
	src = pulse_train(f0, tilt=1.55)
	src += 0.035 * rng.standard_normal(n)  # a little breath
	y = vocal_tract(src, ONSETS[onset], VOWELS[vowel], n, glide_s=0.032)
	if onset == "2":
		# A tiny tongue-tip burst before the voicing, like the "d" in "da".
		burst = np.zeros(n)
		m = int(0.006 * SR)
		burst[:m] = rng.standard_normal(m) * np.linspace(1.0, 0.0, m)
		burst = burst - biquad_lowpass(burst, 2500.0)
		y = y / (np.max(np.abs(y)) or 1.0) + 0.18 * burst
	return finish(y * envelope(n, 0.012, 0.035))


def shout(vowel, name):
	rng = rng_for(name)
	n = int(0.15 * SR)
	t = np.arange(n) / SR
	vib = 1.0 + 0.018 * np.sin(2.0 * np.pi * 6.0 * t)
	f0 = pitch_contour(n, 245.0, rise=0.05, fall=0.09) * vib
	f0 = f0 * (1.0 + 0.02 * smooth_noise(n, rng, 30.0))
	src = pulse_train(f0, tilt=1.05)
	src += 0.06 * rng.standard_normal(n)
	y = vocal_tract(src, ONSETS["2"], VOWELS[vowel], n, glide_s=0.035, bw_scale=0.85, f1_scale=1.12)
	return finish(y * envelope(n, 0.010, 0.05))


def whisper(vowel, name):
	rng = rng_for(name)
	n = int(0.11 * SR)
	src = rng.standard_normal(n)
	src = np.append(src[0], np.diff(src))  # breath is bright: tilt it up
	y = vocal_tract(src, ONSETS["1"], VOWELS[vowel], n, glide_s=0.03, bw_scale=1.6)
	return finish(y * envelope(n, 0.018, 0.045))


def muffled(vowel, name):
	y = talk(vowel, "1", name + "_src")
	y = biquad_lowpass(biquad_lowpass(y, 480.0), 480.0)
	n = len(y)
	return finish(y * envelope(n, 0.02, 0.04))


def write_ogg(path, samples):
	pcm = np.clip(samples * 32767.0, -32768, 32767).astype("<i2")
	with tempfile.TemporaryDirectory() as tmp:
		wav_path = os.path.join(tmp, "in.wav")
		with wave.open(wav_path, "wb") as w:
			w.setnchannels(1)
			w.setsampwidth(2)
			w.setframerate(SR)
			w.writeframes(pcm.tobytes())
		subprocess.run([
			"ffmpeg", "-loglevel", "error", "-y", "-i", wav_path,
			"-map_metadata", "-1", "-c:a", "libvorbis", "-q:a", "4",
			"-ac", "1", "-ar", str(SR), path,
		], check=True)


def main():
	if not shutil.which("ffmpeg"):
		sys.exit("ffmpeg not found (it must be built with libvorbis)")
	os.makedirs(OUT, exist_ok=True)
	made = []
	for v in VOWELS:
		for onset in ONSETS:
			name = f"talk_{v}{onset}"
			made.append((name, talk(v, onset, name)))
		made.append((f"shout_{v}", shout(v, f"shout_{v}")))
		made.append((f"whisper_{v}", whisper(v, f"whisper_{v}")))
		made.append((f"muffled_{v}", muffled(v, f"muffled_{v}")))
	for name, samples in made:
		path = os.path.join(OUT, PREFIX + name + ".ogg")
		write_ogg(path, samples)
		print(f"{os.path.relpath(path)}  {len(samples) / SR * 1000:.0f} ms")


if __name__ == "__main__":
	main()
