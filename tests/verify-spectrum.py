#!/usr/bin/env python3
"""Compare the exact original and optimized FFT implementations on fixed samples."""
from pathlib import Path
import subprocess
import os
import sys

root = Path(__file__).resolve().parents[1]
original = Path(sys.argv[1]).read_text()
optimized = (root / 'Sources/NotchMusic/SystemAudioLevelMonitor.swift').read_text()
out = root / '.build/checks'
out.mkdir(parents=True, exist_ok=True)

def analyzer(text, name, scratch):
    start = text.index('    private func analyzeSpectrum(')
    end = text.index('    private func spectralLevels(', start)
    method = text[start:end].replace('private func', 'func')
    fields = '''
    let fftSize = 2048
    let bandEdges: [Double] = [45, 90, 180, 360, 720, 1400, 2800, 5600, 11000, 20000]
    let bandGain: [Double] = [1.18, 1.14, 1.10, 1.04, 1, 1, 1.04, 1.10, 1.16]
    var smoothedBands = [Double](repeating: 0.06, count: 9)
    let fftSetup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))
    var window = [Float](repeating: 0, count: 2048)
    init() { vDSP_hann_window(&window, 2048, Int32(vDSP_HANN_NORM)) }
    deinit { if let fftSetup { vDSP_destroy_fftsetup(fftSetup) } }
'''
    if scratch:
        a = text.index('    private var fftInput')
        b = text.index('    private var generation', a)
        fields += text[a:b]
    return 'final class ' + name + ' {\n' + fields + method + '\n}\n'

checks = '''
@main struct SpectrumChecks {
    static func main() {
        let before = Original(), after = Optimized()
        for rate in [44100.0, 48000.0, 96000.0] {
            for count in [64, 512, 1024, 2048, 4096] {
                for frequency in [0.0, 45, 440, 2800, 11000, 19000] {
                    let samples = (0..<count).map { Float(sin(2 * .pi * frequency * Double($0) / rate) * 0.4) }
                    for _ in 0..<5 {
                        let a = before.analyzeSpectrum(samples: samples, sampleRate: rate)!
                        let b = after.analyzeSpectrum(samples: samples, sampleRate: rate)!
                        precondition(zip(a, b).allSatisfy { abs($0 - $1) < 1e-12 }, "FFT output changed")
                    }
                }
            }
        }
        precondition(after.analyzeSpectrum(samples: [], sampleRate: 48000) == nil)
        print("PASS: 450 FFT comparisons, 3 sample rates, 5 buffer sizes, 6 frequencies; identical smoothing and band output")
    }
}
'''
generated = out / 'SpectrumChecks.swift'
generated.write_text('import Foundation\nimport Accelerate\n' + analyzer(original, 'Original', False) + analyzer(optimized, 'Optimized', True) + checks)
sdk = str(Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()).resolve())
stable = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk')
if sdk.endswith('MacOSX26.5.sdk') and stable.is_dir(): sdk = str(stable)
os.environ['CLANG_MODULE_CACHE_PATH'] = str(root / '.build/ModuleCache')
subprocess.run(['swiftc', '-O', '-parse-as-library', '-sdk', sdk, str(generated), '-o', str(out / 'SpectrumChecks')], check=True)
subprocess.run([str(out / 'SpectrumChecks')], check=True, timeout=30)
