import 'dart:typed_data';
import 'package:camera/camera.dart';

/// Mean red/green intensity of the centre of a camera frame.
class FrameStat {
  final double red, green;
  FrameStat(this.red, this.green);
  /// Finger over lens + torch => very red frame.
  bool get fingerPresent => red > 120 && green < red * 0.6;
}

FrameStat? frameStat(CameraImage img) {
  try {
    if (img.format.group == ImageFormatGroup.bgra8888) {
      final p = img.planes[0];
      final b = p.bytes;
      double r = 0, g = 0;
      int n = 0;
      for (int y = img.height ~/ 4; y < img.height * 3 ~/ 4; y += 4) {
        for (int x = img.width ~/ 4; x < img.width * 3 ~/ 4; x += 4) {
          final i = y * p.bytesPerRow + x * 4;
          g += b[i + 1];
          r += b[i + 2];
          n++;
        }
      }
      return n == 0 ? null : FrameStat(r / n, g / n);
    }
    if (img.format.group == ImageFormatGroup.yuv420 && img.planes.length >= 3) {
      final py = img.planes[0], pu = img.planes[1], pv = img.planes[2];
      double sy = 0, su = 0, sv = 0;
      int n = 0;
      for (int y = img.height ~/ 4; y < img.height * 3 ~/ 4; y += 4) {
        for (int x = img.width ~/ 4; x < img.width * 3 ~/ 4; x += 4) {
          sy += py.bytes[y * py.bytesPerRow + x];
          final ci = (y >> 1) * pu.bytesPerRow + (x >> 1) * (pu.bytesPerPixel ?? 1);
          final cj = (y >> 1) * pv.bytesPerRow + (x >> 1) * (pv.bytesPerPixel ?? 1);
          su += pu.bytes[ci];
          sv += pv.bytes[cj];
          n++;
        }
      }
      if (n == 0) return null;
      final Y = sy / n, U = su / n - 128, V = sv / n - 128;
      // BT.601 (linear, so channel means can be computed from plane means)
      final r = (Y + 1.402 * V).clamp(0.0, 255.0).toDouble();
      final g = (Y - 0.344136 * U - 0.714136 * V).clamp(0.0, 255.0).toDouble();
      return FrameStat(r, g);
    }
  } catch (_) {}
  return null;
}

/// Linear-resample irregularly timed samples (t in seconds) to a uniform grid.
List<double> resampleUniform(List<double> t, List<double> v, double fs) {
  final out = <double>[];
  if (t.length < 2) return out;
  final t0 = t.first, t1 = t.last;
  int j = 0;
  for (double x = t0; x <= t1; x += 1 / fs) {
    while (j < t.length - 2 && t[j + 1] < x) {
      j++;
    }
    final dt = t[j + 1] - t[j];
    final w = dt <= 0 ? 0.0 : ((x - t[j]) / dt).clamp(0.0, 1.0);
    out.add(v[j] + (v[j + 1] - v[j]) * w);
  }
  return out;
}

/// Effective sampling rate from timestamps.
double effectiveFs(List<double> t) => t.length < 2 ? 0 : (t.length - 1) / (t.last - t.first);

Float64List toF64(List<double> l) => Float64List.fromList(l);
