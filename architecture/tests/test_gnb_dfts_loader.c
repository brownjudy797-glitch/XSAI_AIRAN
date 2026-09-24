#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "openair1/PHY/TOOLS/tools_defs.h"

/* Linked with the real gNB objects, but never calls the renamed modem main. */
int main(int argc, char **argv)
{
  if (argc != 2) return 2;
  if (load_dftslib() != 0 || !dft || !idft) return 3;
  Dl_info info;
  if (!dladdr((void *)dft, &info)) return 4;
  char loaded[4096], expected[4096];
  if (!realpath(info.dli_fname, loaded) || !realpath(argv[1], expected)) return 5;
  printf("DFT_LOADED_PATH %s\n", loaded);
  if (strcmp(loaded, expected)) return 6;
  int16_t input[128] __attribute__((aligned(64))) = {0};
  int16_t output[128] __attribute__((aligned(64))) = {0};
  input[0] = 1024;
  dft(DFT_64, input, output, 1);
  for (int k=0;k<64;++k) if (output[2*k] != 128 || output[2*k+1] != 0) return 7;
  memset(output, 0, sizeof(output));
  idft(IDFT_64, input, output, 1);
  for (int k=0;k<64;++k) if (output[2*k] != 128 || output[2*k+1] != 0) return 8;
  puts("PASS: native OAI loader, actual gNB link dependencies, DFT64/IDFT64 impulse");
  return 0;
}
