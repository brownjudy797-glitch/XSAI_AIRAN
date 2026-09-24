"""Independent NumPy FFT audit of the deterministic full-module test outputs.

An engineering regression gate, not a Q15 bit-exact oracle or radio standard.
Fitted gain is diagnostic, never a pass gate.
"""
from pathlib import Path
import hashlib
import json
import numpy as np

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root/'docs/validation/dfts-module-result.json').read_text())
raw = root/'.build/dfts-correctness'

def samples(count):
    state = 0x12345678
    result = []
    for _ in range(count):
        state ^= (state << 13) & 0xffffffff
        state ^= state >> 17
        state ^= (state << 5) & 0xffffffff
        value = state & 65535
        if value >= 32768:
            value -= 65536
        result.append((1 if value >= 0 else -1) * (abs(value) % 1024))
    return np.asarray(result, dtype=np.float64)

rows = []
for item in manifest['sizes']:
    kind, n, batch = item['direction'], item['size'], item['batch']
    filename = raw/f'{kind}-{n}-0.bin'
    data = np.fromfile(filename, dtype='<i2').reshape(2,4,n,batch,2)
    x = samples(n*batch*2).reshape(n,batch,2)
    x = x[:,:,0] + 1j*x[:,:,1]
    ref = np.fft.fft(x, axis=0) if kind == 'DFT' else np.fft.ifft(x, axis=0)*n
    for scale in (0,1):
        observed = data[scale,2,:,:,0] + 1j*data[scale,2,:,:,1]
        # Impulse at index zero, lane zero; inactive packed lanes must stay zero.
        impulse = data[scale,1,:,:,0] + 1j*data[scale,1,:,:,1]
        gain = np.vdot(ref,observed) / np.vdot(ref,ref)
        fitted = ref*gain
        signal = np.linalg.norm(observed)
        residual = float(np.linalg.norm(observed-fitted)/max(signal,1e-30))
        unitary = ref/np.sqrt(n)
        row = {'direction':kind,'size':n,'batch':batch,'scale':scale,
               'raw_sha256':hashlib.sha256(filename.read_bytes()).hexdigest(),
               'gain_real':float(gain.real),'gain_imag':float(gain.imag),
               'unitary_gain_ratio':float(abs(gain)*np.sqrt(n)),
               'gain_fitted_relative_residual':residual,
               'unitary_relative_error':float(np.linalg.norm(observed-unitary)/np.linalg.norm(unitary)),
               'peak_component':int(np.max(np.abs(data[scale,2].astype(np.int32)))),
               'impulse_real_min':float(impulse[:,0].real.min()),
               'impulse_real_max':float(impulse[:,0].real.max()),
               'impulse_imag_max':float(np.max(np.abs(impulse[:,0].imag))),
               'inactive_lane_max':float(np.max(np.abs(impulse[:,1:]))) if batch>1 else 0.0}
        rows.append(row)
        # Source contract: dft12 ignores scale_flag; nr_ulsch_demodulation.c
        # applies its normalization externally. Never infer this gain from output.
        expected = ref if kind == 'DFT' and n == 12 else unitary
        row['normalization_contract'] = 'unscaled dft12; caller normalizes' if kind == 'DFT' and n == 12 else 'unitary for scale=1'
        row['contract_relative_error'] = float(np.linalg.norm(observed-expected)/np.linalg.norm(expected))
        row['contract_gate_pass'] = (row['contract_relative_error'] <= .01 and
                                   row['inactive_lane_max'] == 0 and row['impulse_imag_max'] == 0) if scale == 1 else None
checked = [r for r in rows if r['scale'] == 1]
result = {'method':'NumPy complex128 FFT; exact C xorshift and signed remainder input reproduction; random-small pattern. Fixed source-contract normalization (unitary except unscaled DFT12, not fitted gain) gates scale=1 at relative L2 error <=1%; zero inactive impulse lanes and zero imaginary impulse output required. This project engineering threshold is not an OAI/3GPP precision specification. Scale=0 remains diagnostic because stage scaling differs by size.',
          'numpy_version':np.__version__,
          'library_sha256':hashlib.sha256((root/'.build/dfts-module/libdfts.so').read_bytes()).hexdigest(),
          'summary':{'checked':len(checked),'passed':sum(r['contract_gate_pass'] for r in checked),
                     'max_contract_relative_error':max(r['contract_relative_error'] for r in checked)}, 'rows':rows}
out = root/'.build/dfts-numerics'
out.mkdir(exist_ok=True)
(out/'result.json').write_text(json.dumps(result,indent=2))
for r in sorted((r for r in rows if r['scale']==1),key=lambda r:r['gain_fitted_relative_residual'],reverse=True)[:20]:
    print(r['direction'],r['size'],'gain=',round(r['unitary_gain_ratio'],5),'residual=',round(r['gain_fitted_relative_residual'],5),'impulse=',r['impulse_real_min'],r['impulse_real_max'],'leak=',r['inactive_lane_max'])
print(json.dumps(result['summary']))
raise SystemExit(0 if all(r['contract_gate_pass'] for r in checked) else 1)
