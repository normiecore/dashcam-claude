#!/usr/bin/env python3
"""Check the portable scene tone stage (RecoveredColor.cpp) on Linux.

Compiles the app's own C++ core and verifies identity, monotonic tone,
highlight containment, the Standard-curve grey targets and scene measurement.
Requires numpy and a C++17 compiler; uses only repository resources.
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
        lib.hn_measure_scene.argtypes = [P, ctypes.c_size_t, ctypes.POINTER(Stats)]
        lib.hn_choose_scene_tone.argtypes = [ctypes.POINTER(Stats), F, ctypes.POINTER(Tone)]
        lib.hn_toned_pixel_with_curve.argtypes = [P, ctypes.POINTER(Tone), P, ctypes.c_size_t, ctypes.c_size_t,
                                                  F, F, F, F, P, ctypes.c_size_t, P]
        profile = json.loads((RES / 'ReferenceProfile.json').read_text())
        chroma = np.fromfile(RES / 'ReferenceChroma.f32', dtype='<f4')
        film = np.fromfile(RES / 'StandardCurve.f32', dtype='<f4')

        def tone(rgb, t):
            src = (F * 3)(*rgb)
            dst = (F * 3)()
            assert lib.hn_apply_scene_tone(src, ctypes.byref(t), dst) == 1
            return list(dst)

        def render(rgb, t):
            src = (F * 3)(*rgb)
            dst = (F * 3)()
            assert lib.hn_toned_pixel_with_curve(src, ctypes.byref(t), chroma.ctypes.data_as(P), profile['width'],
                                                 profile['height'], profile['start'][0], profile['start'][1],
                                                 profile['divisor'], 1.0, film.ctypes.data_as(P), 65536, dst) == 1
            return list(dst)

        identity = Tone(1, 0, 0)
        rng = np.random.default_rng(2026)
        for rgb in rng.uniform(0, 3, (500, 3)).astype(np.float32):
            assert tone(list(rgb), identity) == [float(v) for v in rgb], 'identity must be exact'

        # Standard curve design point: with a calibrated exposure that places
        # an 18% card at 0.125, the documented camera targets are met.
        exposure = 0.125 / 0.18
        ladder = {}
        for stops in (0, 1, 2):
            v = 0.18 * 2 ** stops
            ladder[f'+{stops}EV'] = round(srgb8(render([v, v, v], Tone(exposure, 0, 0))[1]), 1)
        assert abs(ladder['+0EV'] - 118.5) <= 1.5 and abs(ladder['+1EV'] - 172) <= 2.5 and abs(ladder['+2EV'] - 224) <= 2.5, ladder
        results['grey_ladder_srgb8'] = ladder

        # Monotonic neutral response and containment for every allowed setting.
        grid = 0.18 * 2 ** np.linspace(-12, 6, 4000)
        worst_slope = math.inf
        for d in np.linspace(0, 2.5, 11):
            for fill in np.linspace(0, 0.6, 7):
                t = Tone(exposure, float(d), float(fill))
                out = np.array([tone([float(v)] * 3, t)[0] for v in grid])
                logs = np.log2(out)
                slope = np.diff(logs) / np.diff(np.log2(grid))
                worst_slope = min(worst_slope, float(slope.min()))
                assert slope.min() > 0.05, (d, fill, slope.min())
                white = 2 ** d / exposure
                # Scene white for this compression maps to film white within float error.
                assert tone([white] * 3, t)[0] <= 1.0001, (d, fill)
        results['minimum_log_slope'] = round(worst_slope, 4)

        # Hue preservation: channel ratios are unchanged by the gain.
        t = Tone(exposure, 2.0, 0.4)
        for rgb in rng.uniform(0.001, 4, (500, 3)):
            out = tone(list(rgb), t)
            ratio = np.array(out) / (np.array(rgb) * exposure)
            assert np.ptp(ratio) < 1e-5 * ratio.mean(), 'gain must be shared by channels'

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
        bad = Tone(exposure, 3.0, 0)
        assert lib.hn_apply_scene_tone((F * 3)(0.1, 0.1, 0.1), ctypes.byref(bad), (F * 3)()) == 0
    print(json.dumps({'scene_tone_checks': 'pass', **results}, indent=1))


if __name__ == '__main__':
    sys.exit(main())
