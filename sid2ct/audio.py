"""Compare SID reconstruction WAVs with legacy and perceptual audio scores.

Similarity is a heuristic for ranking candidates, never an equivalence proof.
"""
from array import array
import cmath
import math
import os
from concurrent.futures import ProcessPoolExecutor
from functools import lru_cache
from pathlib import Path
import sys
import wave

try:
    import numpy as np
except ImportError:
    np = None


def load_wav(path):
    with wave.open(str(path), 'rb') as wav:
        if wav.getnchannels() != 1 or wav.getsampwidth() != 2 or wav.getcomptype() != 'NONE':
            raise ValueError('Audio comparison requires mono PCM16 WAV.')
        rate = wav.getframerate()
        pcm = array('h', wav.readframes(wav.getnframes()))
    if sys.byteorder != 'little':
        pcm.byteswap()
    if not pcm:
        raise ValueError('Empty WAV recording.')
    return rate, pcm


def rms(values):
    return (float(np.sqrt(np.mean(np.asarray(values, dtype=float)**2))) if np is not None
            else math.sqrt(sum(x*x for x in values) / len(values))) if len(values) else 0.0


def envelope(pcm, size):
    if np is not None:
        values = np.asarray(pcm, dtype=float)[:len(pcm)//size*size].reshape(-1, size)
        return np.sqrt(np.mean(values**2, axis=1)).tolist()
    return [rms(pcm[i:i+size]) for i in range(0, len(pcm)-size+1, size)]


def fft(values):
    """Iterative radix-2 FFT; used only for coarse spectral comparison."""
    out = [complex(v) for v in values]
    n = len(out)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            out[i], out[j] = out[j], out[i]
    width = 2
    while width <= n:
        half = width // 2
        step = cmath.exp(-2j * math.pi / width)
        weights = [step ** k for k in range(half)]
        for start in range(0, n, width):
            for k, weight in enumerate(weights):
                a, b = out[start+k], out[start+k+half] * weight
                out[start+k], out[start+k+half] = a+b, a-b
        width *= 2
    return out


def _serial_spectral_features(pcm, rate):
    size, hop, bands = 1024, 512, 32
    window = [0.5 - 0.5*math.cos(2*math.pi*i/(size-1)) for i in range(size)]
    bins = [(k, min(bands-1, int(math.log((k*rate/size)/40, (rate/2)/40)*bands)))
            for k in range(1, size//2+1) if k*rate/size >= 40]
    result = []
    for start in range(0, len(pcm)-size+1, hop):
        spectrum = fft([pcm[start+i]*window[i] for i in range(size)])
        power = [0.0]*bands
        for k, band in bins:
            power[band] += abs(spectrum[k]) ** 2
        # Square-root energy softens the dominance of one loud harmonic.
        magnitude = [math.sqrt(p) for p in power]
        norm = math.sqrt(sum(p*p for p in magnitude))
        result.append([p/norm for p in magnitude] if norm > 0 else magnitude)
    return result


def analysis_workers():
    override = os.environ.get('SID2CT_WORKERS')
    if override is not None:
        workers = int(override)
        if workers < 1:
            raise ValueError('Analysis workers must be positive.')
        return workers
    available = getattr(os, 'process_cpu_count', os.cpu_count)()
    return max(1, available or 1)


@lru_cache(maxsize=1)
def _analysis_pool(workers):
    # Separate processes bypass Python's GIL for the dependency-free FFT.
    return ProcessPoolExecutor(max_workers=workers)


def _spectral_job(job):
    return _serial_spectral_features(*job)


def spectral_features(pcm, rate):
    if np is not None:
        frames = _frames(pcm, 1024, 512)
        power = abs(np.fft.rfft(frames*np.hanning(1024), axis=1))**2
        features = np.zeros((len(frames), 32))
        for k in range(1, 513):
            if k*rate/1024 >= 40:
                band = min(31, int(math.log((k*rate/1024)/40, (rate/2)/40)*32))
                features[:, band] += power[:, k]
        features = np.sqrt(features)
        norms = np.linalg.norm(features, axis=1, keepdims=True)
        return features/np.where(norms > 0, norms, 1)
    workers = analysis_workers()
    count = max(0, (len(pcm)-1024)//512+1)
    if workers == 1 or count < 128:
        return _serial_spectral_features(pcm, rate)
    # Each block includes its last overlapping FFT window, with no duplicate
    # or missing windows at a boundary. map preserves the original time order.
    jobs = [(pcm[start*512:(min(count,start+128)-1)*512+1024], rate)
            for start in range(0, count, 128)]
    return [feature for block in _analysis_pool(workers).map(_spectral_job, jobs)
            for feature in block]


@lru_cache(maxsize=2)
def _cached_spectral_features(pcm_bytes, rate, workers):
    # Identical aligned excerpts recur in fixed/independent voice diagnostics.
    # Limit retained PCM/features to two excerpts rather than a whole song set.
    return spectral_features(array('h', pcm_bytes), rate)


def _frames(pcm, size, hop):
    values = np.asarray(pcm, dtype=float)
    if len(values) < size:
        return np.empty((0, size))
    return np.lib.stride_tricks.sliding_window_view(values, size)[::hop]


def _v2(x, y, rate, envelope_score, overlap):
    """Log-mel, positive envelope flux and pitch-class agreement on aligned PCM."""
    mel_scores, chroma_scores = [], []
    for size in (256, 1024, 4096):
        hop = size//2
        if len(x) < size:
            continue
        frequencies = [k*rate/size for k in range(size//2+1)]
        mel = lambda hz: 2595*math.log10(1+hz/700)
        edges = [mel(rate/2)*i/41 for i in range(42)]
        weights = [[max(0., min((mel(f)-edges[j])/(edges[j+1]-edges[j]),
                                  (edges[j+2]-mel(f))/(edges[j+2]-edges[j+1])))
                    for f in frequencies] for j in range(40)]
        pitch = [int(round(69+12*math.log2(f/440)))%12 if f >= 40 else -1 for f in frequencies]
        if np is not None:
            spectra = [abs(np.fft.rfft(_frames(v,size,hop)*np.hanning(size), axis=1))**2 for v in (x,y)]
            # Explicit sums avoid BLAS thread startup and oversubscription.
            mels = [np.stack([np.sum(p*np.asarray(w),axis=1) for w in weights],axis=1) for p in spectra]
            logs = [np.log1p(m/(32768**2*size)) for m in mels]
            distance = float(np.sum(abs(logs[0]-logs[1]))/max(1e-12,float(np.sum(logs[0]+logs[1]))))
            chromas = [np.stack([np.sum(p[:,np.asarray(pitch)==j],axis=1) for j in range(12)],axis=1) for p in spectra]
            norms = [np.linalg.norm(c,axis=1,keepdims=True) for c in chromas]
            normalized = [c/np.maximum(n,1e-12) for c,n in zip(chromas,norms)]
            chroma = 1-float(np.mean(np.sum((normalized[0]-normalized[1])**2,axis=1)))/2
        else:
            sparse_weights = [[(k,w) for k,w in enumerate(band) if w] for band in weights]
            pitch_bins = [[k for k,pc in enumerate(pitch) if pc==j] for j in range(12)]
            distance_sum = energy_sum = chroma_sum = count = 0.
            window = [.5-.5*math.cos(2*math.pi*i/(size-1)) for i in range(size)]
            for start in range(0,len(x)-size+1,hop):
                spectra = [[abs(v)**2 for v in fft([pcm[start+i]*window[i] for i in range(size)])[:size//2+1]] for pcm in (x,y)]
                logs = [[math.log1p(sum(power[k]*w for k,w in band)/(32768**2*size)) for band in sparse_weights] for power in spectra]
                distance_sum += sum(abs(a-b) for a,b in zip(*logs))
                energy_sum += sum(map(sum,logs))
                cs = [[sum(power[k] for k in bins) for bins in pitch_bins] for power in spectra]
                ns = [math.sqrt(sum(v*v for v in c)) for c in cs]
                chroma_sum += sum((a/max(ns[0],1e-12)-b/max(ns[1],1e-12))**2 for a,b in zip(*cs))/2
                count += 1
            distance = distance_sum/max(energy_sum,1e-12)
            chroma = 1-chroma_sum/max(count,1)
        mel_scores.append(max(0.,1-distance))
        chroma_scores.append(max(0.,chroma))
    ea, eb = envelope(x,max(1,rate//100)), envelope(y,max(1,rate//100))
    flux = [[max(0.,b-a) for a,b in zip(e,e[1:])] for e in (ea,eb)]
    onset = 1-math.sqrt(sum((a-b)**2 for a,b in zip(*flux))/max(1,sum(v*v for f in flux for v in f)))
    components = dict(log_mel_similarity=sum(mel_scores)/max(1,len(mel_scores)),
                      chroma_similarity=sum(chroma_scores)/max(1,len(chroma_scores)),
                      onset_similarity=max(0.,onset), envelope_similarity=envelope_score)
    score = (.55*components['log_mel_similarity']+.2*components['chroma_similarity']+
             .15*components['onset_similarity']+.1*envelope_score)*overlap
    return round(max(0.,min(1.,score)),6), {k:round(v,6) for k,v in components.items()}


def score_value(audio, score='v2'):
    return audio.get('score_'+score, audio.get('similarity'))


def compare_wavs(source, reconstruction, max_lag_ms=250, *, fixed_alignment_ms=None):
    rate, a = load_wav(source)
    other_rate, b = load_wav(reconstruction)
    if rate != other_rate:
        raise ValueError('WAV sample rates differ.')
    ar, br = rms(a), rms(b)
    common = min(len(a), len(b))
    step = max(1, rate//100)  # 10 ms alignment grid
    fixed_lag = None
    if fixed_alignment_ms is not None:
        if not math.isfinite(fixed_alignment_ms):
            raise ValueError('Fixed alignment must be finite.')
        fixed_lag = round(fixed_alignment_ms*rate/1000/step)
        if abs(fixed_lag)*step >= common:
            raise ValueError('Fixed alignment leaves no overlapping audio.')
    result = dict(sample_rate=rate, source_samples=len(a), reconstruction_samples=len(b),
                  source_rms=round(ar, 3), reconstruction_rms=round(br, 3),
                  pcm_equal=(len(a) == len(b) and a == b),
                  exact_match=False, verdict='different')
    # Two silent recordings must not be advertised as successful recovery.
    if ar < 2 or br < 2 or common < 1024:
        result.update(verdict='inconclusive', similarity=None, score_v1=None, score_v2=None, score_v2_components={}, alignment_ms=0,
                      reason='Silent/near-silent or too-short recording.')
        return result
    if result['pcm_equal'] and fixed_lag in (None, 0):
        result.update(verdict='exact', exact_match=True, similarity=1.0, alignment_ms=0,
                      score_v1=1.0, score_v2=1.0,
                      score_v2_components=dict(log_mel_similarity=1., chroma_similarity=1., onset_similarity=1., envelope_similarity=1.),
                      envelope_similarity=1.0, spectral_similarity=1.0, overlap_fraction=1.0,
                      normalized_pcm_error=0.0)
        return result
    ea, eb = envelope(a, step), envelope(b, step)
    limit = min(round(max_lag_ms*rate/1000/step), max(0, min(len(ea), len(eb))//10))
    best = None
    for lag in ([fixed_lag] if fixed_lag is not None else range(-limit, limit+1)):
        sa, sb = max(0, -lag), max(0, lag)
        count = min(len(ea)-sa, len(eb)-sb)
        x, y = ea[sa:sa+count], eb[sb:sb+count]
        energy = sum(v*v for v in x) + sum(v*v for v in y)
        error = sum((p-q)**2 for p, q in zip(x, y)) / max(1, energy)
        # Prefer the smallest offset when envelopes give equal evidence.
        key = (error, abs(lag))
        if best is None or key < best[0]:
            best = (key, lag)
    error, lag = best[0][0], best[1]
    sa, sb = max(0, -lag)*step, max(0, lag)*step
    count = min(len(a)-sa, len(b)-sb)
    x, y = a[sa:sa+count], b[sb:sb+count]
    workers = analysis_workers()
    fa = _cached_spectral_features(x.tobytes(), rate, workers)
    fb = _cached_spectral_features(y.tobytes(), rate, workers)
    if np is not None:
        frames = _frames(x, 1024, 512)
        weights = np.sqrt(np.mean(frames**2, axis=1))
        weight_sum = float(np.sum(weights))
        spectral_error = float(np.sum(weights*np.sum((fa-fb)**2,axis=1)/2))
    else:
        weight_sum, spectral_error = 0.0, 0.0
        for i, (p, q) in enumerate(zip(fa, fb)):
            weight = rms(x[i*512:i*512+1024])
            spectral_error += weight * sum((v-w)**2 for v, w in zip(p, q)) / 2
            weight_sum += weight
    spectral_similarity = max(0.0, 1 - spectral_error/max(1, weight_sum))
    envelope_similarity = max(0.0, 1 - math.sqrt(error))
    overlap = count / max(len(a), len(b))
    score = (0.7*spectral_similarity + 0.3*envelope_similarity) * overlap
    pcm_error = (rms(np.asarray(x,dtype=float)-np.asarray(y,dtype=float)) if np is not None
                 else math.sqrt(sum((p-q)**2 for p,q in zip(x,y))/count))/max(ar,1)
    v2, components = _v2(x,y,rate,envelope_similarity,overlap)
    result.update(score_v1=round(score,6), score_v2=v2, score_v2_components=components)
    result.update(similarity=round(score, 6), alignment_ms=round(lag*step*1000/rate, 3),
                  envelope_similarity=round(envelope_similarity, 6),
                  spectral_similarity=round(spectral_similarity, 6),
                  overlap_fraction=round(overlap, 6), normalized_pcm_error=round(pcm_error, 6))
    return result
