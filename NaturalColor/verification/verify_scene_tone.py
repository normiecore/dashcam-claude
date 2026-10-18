#!/usr/bin/env python3
"""Check the portable scene tone stage (RecoveredColor.cpp) on Linux.

Compiles the app's own C++ core and verifies identity, monotonic tone,
highlight containment, the Standard-curve grey anchors, the neutral path to
white, the HDR gain and scene measurement. Requires numpy and a C++17
compiler; uses only repository resources.
"""
import ctypes, json, math, subprocess, sys, tempfile
from pathlib import Path
import numpy as np

APP = Path(__file__).resolve().parents[1]
RES = APP / 'ios/HassyNatural/Resources'
F = ctypes.c_float
P = ctypes.POINTER(F)


class Tone(ctypes.Structure):
    _fields_ = [('exposure', F), ('compression', F), ('shadowFill', F)]


class Stats(ctypes.Structure):
    _fields_ = [('white', F), ('darkFraction', F)]


def srgb8(v):
    v = min(max(v, 0.0), 1.0)
    return 255 * (12.92 * v if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055)


def main():
    results = {}
    with tempfile.TemporaryDirectory() as td:
        lib_path = Path(td) / 'recovered.so'
        subprocess.run(['c++', '-std=c++17', '-O2', '-ffp-contract=off', '-shared', '-fPIC',
                        str(APP / 'ios/HassyNatural/Core/RecoveredColor.cpp'), '-o', str(lib_path)], check=True)
        lib = ctypes.CDLL(str(lib_path))
        lib.hn_apply_scene_tone.argtypes = [P, ctypes.POINTER(Tone), P]
        lib.hn_scene_highlight_ev.argtypes = [P, ctypes.POINTER(Tone), P]
        lib.hn_measure_scene.argtypes = [P, ctypes.c_size_t, ctypes.POINTER(Stats)]
        lib.hn_choose_scene_tone.argtypes = [ctypes.POINTER(Stats), F, ctypes.POINTER(Tone)]
        lib.hn_toned_pixel_with_curve.argtypes = [P, ctypes.POINTER(Tone), P, ctypes.c_size_t, ctypes.c_size_t,
                                                  F, F, F, F, P, ctypes.c_size_t, P]
        profile = json.loads((RES / 'ReferenceProfile.json').read_text())
        chroma = np.fromfile(RES / 'ReferenceChroma.f32', dtype='<f4')
        film = np.fromfile(RES / 'StandardCurve.f32', dtype='<f4')

        def tone(rgb, t):
            dst = (F * 3)()
            assert lib.hn_apply_scene_tone((F * 3)(*rgb), ctypes.byref(t), dst) == 1
            return list(dst)

        def hdr_ev(rgb, t):
            ev = F()
            assert lib.hn_scene_highlight_ev((F * 3)(*rgb), ctypes.byref(t), ctypes.byref(ev)) == 1
            return ev.value

        def render(rgb, t):
            dst = (F * 3)()
            assert lib.hn_toned_pixel_with_curve((F * 3)(*rgb), ctypes.byref(t), chroma.ctypes.data_as(P),
                                                 profile['width'], profile['height'], profile['start'][0],
                                                 profile['start'][1], profile['divisor'], 1.0,
                                                 film.ctypes.data_as(P), 65536, dst) == 1
            return list(dst)

        identity = Tone(1, 0, 0)
        rng = np.random.default_rng(2026)
        for rgb in rng.uniform(0, 3, (500, 3)).astype(np.float32):
            assert tone(list(rgb), identity) == [float(v) for v in rgb], 'identity must be exact'

        # Standard curve design point (calibrated exposure places 18% at 0.125).
        exposure = 0.125 / 0.18
        ladder = {}
        for d in (0.0, 2.5):
            row = [round(srgb8(render([0.18 * 2 ** s] * 3, Tone(exposure, d, 0))[1]), 1) for s in range(6)]
            ladder[f'compression {d}'] = row
        plain, folded = ladder['compression 0.0'], ladder['compression 2.5']
        assert abs(plain[0] - 118.5) <= 1.5 and abs(plain[1] - 172) <= 2.5 and abs(plain[2] - 224) <= 2.5, plain
        assert folded[0] == plain[0] and folded[1] == plain[1], 'grey and +1 EV keep the curve exactly'
        assert folded[2] >= 212 and all(b > a for a, b in zip(folded, folded[1:])), folded
        results['grey_ladder_srgb8_0_to_5EV'] = ladder

        # Monotonic neutral response and containment for every allowed setting.
        grid = 0.18 * 2 ** np.linspace(-12, 6, 4000)
        worst_slope = math.inf
        for d in np.linspace(0, 2.5, 11):
            for fill in np.linspace(0, 0.6, 7):
                t = Tone(exposure, float(d), float(fill))
                out = np.array([tone([float(v)] * 3, t)[0] for v in grid])
                slope = np.diff(np.log2(out)) / np.diff(np.log2(grid))
                worst_slope = min(worst_slope, float(slope.min()))
                assert slope.min() > 0.05, (d, fill, slope.min())
                # The measured white (3 + d stops above film grey) lands on film white.
                white = 0.125 * 2 ** (3 + d) / exposure
                assert abs(tone([white] * 3, t)[0] - 1.0) < 2e-4, (d, fill, tone([white] * 3, t))
        results['minimum_log_slope'] = round(worst_slope, 4)

        # Hue preservation below the path-to-white band; neutral at film white.
        t = Tone(exposure, 2.0, 0.4)
        for rgb in rng.uniform(0.001, 4, (2000, 3)):
            out = np.array(tone(list(rgb), t))
            if out.max() < 0.9:
                ratio = out / (np.array(rgb) * exposure)
                assert np.ptp(ratio) < 1e-5 * ratio.mean(), 'gain must be shared by channels'
            elif out.max() >= 1.0:
                assert np.ptp(out) < 1e-6, 'film white is neutral'
        quiet = Tone(1, 0, 0.3)
        out = tone([0.95, 0.2, 0.1], quiet)
        assert abs(out[1] / out[0] - 0.2 / 0.95) < 1e-6, 'no path to white without compression'

        # HDR gain restores exactly the folded stops, capped at 3 stops.
        t = Tone(1, 2.5, 0)
        assert hdr_ev([0.2, 0.2, 0.2], t) == 0, 'below the knee SDR and HDR are identical'
        for v in (0.4, 1.0, 3.0, 5.6):
            sdr_peak = max(tone([v, v * 0.7, v * 0.4], Tone(1, 2.5, 0)))
            ev = hdr_ev([v, v * 0.7, v * 0.4], t)
            if sdr_peak < 0.9:
                assert abs(sdr_peak * 2 ** ev - v) < 1e-4 * v, (v, sdr_peak, ev)
        assert hdr_ev([1000, 1000, 1000], t) == 3.0
        results['hdr_stops_at_measured_white'] = round(hdr_ev([2 ** 2.5] * 3, t), 4)

        # Measurement and choice on synthetic scenes.
        flat = np.tile(np.array([0.18, 0.18, 0.18, 1], np.float32), 10000)
        stats = Stats()
        assert lib.hn_measure_scene(flat.ctypes.data_as(P), 10000, ctypes.byref(stats)) == 1
        chosen = Tone()
        assert lib.hn_choose_scene_tone(ctypes.byref(stats), 0, ctypes.byref(chosen)) == 1
        # The RAW placement stays Apple's (1.0) until a grey-card calibration.
        assert chosen.compression == 0 and chosen.shadowFill == 0 and chosen.exposure == 1.0
        backlit = np.concatenate([np.tile([0.012, 0.012, 0.012, 1], 4000), np.tile([0.18, 0.18, 0.18, 1], 3000),
                                  np.tile([3.2, 3.4, 3.6, 1], 3000)]).astype(np.float32)
        assert lib.hn_measure_scene(backlit.ctypes.data_as(P), 10000, ctypes.byref(stats)) == 1
        assert abs(stats.white - 3.6) < 1e-5 and abs(stats.darkFraction - 0.4) < 1e-6
        assert lib.hn_choose_scene_tone(ctypes.byref(stats), 0, ctypes.byref(chosen)) == 1
        assert abs(chosen.compression - min(math.log2(3.6), 2.5)) < 1e-5
        assert 0.5 < chosen.shadowFill <= 0.6
        results['backlit_choice'] = {'compression': round(chosen.compression, 4), 'shadowFill': round(chosen.shadowFill, 4)}
        assert lib.hn_choose_scene_tone(ctypes.byref(stats), -1.5, ctypes.byref(chosen)) == 1
        assert abs(chosen.compression - max(0.0, math.log2(3.6 * 2 ** -1.5))) < 1e-5
        # A dim, low-key scene without bright highlights keeps its mood.
        dim = np.concatenate([np.tile([0.012, 0.012, 0.012, 1], 4000), np.tile([0.3, 0.3, 0.3, 1], 6000)]).astype(np.float32)
        assert lib.hn_measure_scene(dim.ctypes.data_as(P), 10000, ctypes.byref(stats)) == 1
        assert lib.hn_choose_scene_tone(ctypes.byref(stats), 0, ctypes.byref(chosen)) == 1
        assert abs(stats.darkFraction - 0.4) < 1e-6 and chosen.shadowFill == 0 and chosen.compression == 0
        bad = Tone(exposure, 3.0, 0)
        assert lib.hn_apply_scene_tone((F * 3)(0.1, 0.1, 0.1), ctypes.byref(bad), (F * 3)()) == 0
    print(json.dumps({'scene_tone_checks': 'pass', **results}, indent=1))


if __name__ == '__main__':
    sys.exit(main())
