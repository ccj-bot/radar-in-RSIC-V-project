"""Existing complex-echo synthesis, IFFT compression and spherical BP kernels.
Extracted without algorithm edits from the source snapshots in provenance/.
"""

import math

import numpy as np

from numba import njit, prange

C = 3e8

NFFT = 8192

@njit(parallel=True, cache=True)
def backproject(q, apx, hrrp, drange, fref):
    output = np.zeros(len(q), dtype=np.complex128)
    scale = 4 * np.pi * fref / C
    for i in prange(len(q)):
        xx, yy = q[i, 0], q[i, 1]
        value = 0j
        for m in range(len(apx)):
            distance = math.sqrt((xx - apx[m]) ** 2 + yy ** 2)
            index = distance / drange
            k = int(math.floor(index))
            if k < 0 or k + 1 >= hrrp.shape[1]:
                continue
            fraction = index - k
            val = hrrp[m, k] * (1 - fraction) + hrrp[m, k + 1] * fraction
            phase = scale * distance
            value += val * complex(math.cos(phase), math.sin(phase))
        output[i] = value / len(apx)
    return output

@njit(parallel=True, cache=True)
def synthesize(points, coeff, apx, first_frequency, df, nr):
    result = np.zeros((len(apx), nr), dtype=np.complex128)
    for m in prange(len(apx)):
        for j in range(len(points)):
            r = math.sqrt((points[j, 0] - apx[m]) ** 2 + points[j, 1] ** 2)
            p0 = -4 * np.pi * first_frequency * r / C
            pd = -4 * np.pi * df * r / C
            z = coeff[j] * complex(math.cos(p0), math.sin(p0))
            step = complex(math.cos(pd), math.sin(pd))
            for n in range(nr):
                result[m, n] += z
                z *= step
    return result

def compress(echo, retained):
    z = np.fft.ifft(echo, n=NFFT, axis=1)*(NFFT/retained)
    z *= np.exp(-1j*2*np.pi*(echo.shape[1]-1)/2*np.arange(NFFT)/NFFT)[None, :]
    return np.ascontiguousarray(z.astype(np.complex64))
