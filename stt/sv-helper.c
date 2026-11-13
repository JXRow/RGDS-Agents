// Push-to-talk ASR helper (sherpa-onnx SenseVoice).
// stdin:  "PCM <nsamples>\n" + nsamples*int16le (16 kHz mono)   |  "QUIT\n"
// stdout: "READY load_ms=<ms>\n", then one JSON line per request.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "sherpa-onnx/c-api/c-api.h"

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static void json_str(const char *s) {
  putchar('"');
  for (; *s; ++s) {
    if (*s == '"' || *s == '\\') putchar('\\');
    if (*s == '\n') { fputs("\\n", stdout); continue; }
    putchar(*s);
  }
  putchar('"');
}

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: %s model.onnx tokens.txt threads\n", argv[0]);
    return 2;
  }
  SherpaOnnxOfflineRecognizerConfig c;
  memset(&c, 0, sizeof(c));
  c.feat_config.sample_rate = 16000;
  c.feat_config.feature_dim = 80;
  c.model_config.sense_voice.model = argv[1];
  c.model_config.sense_voice.language = "auto";
  c.model_config.sense_voice.use_itn = 1;
  c.model_config.tokens = argv[2];
  c.model_config.num_threads = atoi(argv[3]);
  c.model_config.provider = "cpu";
  c.decoding_method = "greedy_search";

  double t0 = now_ms();
  const SherpaOnnxOfflineRecognizer *rec = SherpaOnnxCreateOfflineRecognizer(&c);
  if (!rec) { fprintf(stderr, "failed to create recognizer\n"); return 1; }
  printf("READY load_ms=%.0f\n", now_ms() - t0);
  fflush(stdout);

  char line[128];
  int16_t *pcm = NULL;
  float *f = NULL;
  size_t cap = 0;
  while (fgets(line, sizeof(line), stdin)) {
    long n = 0;
    if (strncmp(line, "QUIT", 4) == 0) break;
    if (sscanf(line, "PCM %ld", &n) != 1 || n <= 0 || n > 16000 * 60) continue;
    if ((size_t)n > cap) {
      cap = n;
      pcm = realloc(pcm, cap * sizeof(int16_t));
      f = realloc(f, cap * sizeof(float));
    }
    if (fread(pcm, sizeof(int16_t), n, stdin) != (size_t)n) break;
    double a = now_ms();
    for (long i = 0; i < n; ++i) f[i] = pcm[i] / 32768.0f;
    const SherpaOnnxOfflineStream *s = SherpaOnnxCreateOfflineStream(rec);
    SherpaOnnxAcceptWaveformOffline(s, 16000, f, n);
    SherpaOnnxDecodeOfflineStream(rec, s);
    const SherpaOnnxOfflineRecognizerResult *r = SherpaOnnxGetOfflineStreamResult(s);
    double b = now_ms();
    printf("{\"decode_ms\":%.1f,\"lang\":", b - a);
    json_str(r->lang ? r->lang : "");
    fputs(",\"text\":", stdout);
    json_str(r->text);
    puts("}");
    fflush(stdout);
    SherpaOnnxDestroyOfflineRecognizerResult(r);
    SherpaOnnxDestroyOfflineStream(s);
  }
  SherpaOnnxDestroyOfflineRecognizer(rec);
  free(pcm);
  free(f);
  return 0;
}
