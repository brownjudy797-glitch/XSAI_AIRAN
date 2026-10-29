/* SPDX-License-Identifier: Apache-2.0 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Calls the deployed OAI DFT ABI. The size index MUST be resolved from the
 * matching tools_defs.h, not inferred from RB count. No replacement FFT. */
typedef void (*transform_fn)(uint8_t, int16_t *, int16_t *, unsigned char);
extern int logInit(void);
static uint64_t ns(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC_RAW, &t)) abort();
  return (uint64_t)t.tv_sec * 1000000000ULL + t.tv_nsec;
}
static int compare(const void *a, const void *b) {
  double x=*(const double *)a,y=*(const double *)b;
  return (x>y)-(x<y);
}
int main(int argc, char **argv) {
  if (argc!=6) {
    fprintf(stderr,"usage: %s libdfts.so size_index N iterations round\n",argv[0]);
    return 2;
  }
  int index=atoi(argv[2]), n=atoi(argv[3]), it=atoi(argv[4]), round=atoi(argv[5]);
  if(index<0||index>255||n<64||n>4096||it<100||it>1000000||round<1)return 2;
  logInit();
  void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
  if(!lib){fprintf(stderr,"dlopen: %s\n",dlerror());return 3;}
  /* OAI's module loader calls this hook after dlopen. It initializes twiddles
   * needed by larger transforms and must run outside the timed region. */
  int (*initialize)(void)=(int (*)(void))dlsym(lib,"dfts_autoinit");
  if(!initialize||initialize()!=0){fprintf(stderr,"DFT initialization failed\n");return 3;}
  transform_fn fn=(transform_fn)dlsym(lib,"dft_implementation");
  if(!fn){fprintf(stderr,"dlsym: %s\n",dlerror());return 3;}
  int16_t *in=NULL,*out=NULL;
  /* Extra padded lanes mirror OAI test allocation and protect SIMD tails. */
  if(posix_memalign((void **)&in,64,48*n)||posix_memalign((void **)&out,64,48*n))return 4;
  memset(in,0,48*n);memset(out,0,48*n);
  uint32_t seed=42;
  for(int j=0;j<2*n;j++){seed=1664525*seed+1013904223;in[j]=(int16_t)((seed>>16)%257)-128;}
  fn(index,in,out,1);
  double error=0,signal=0;
  for(int k=0;k<n;k++){
    double re=0,im=0;
    for(int j=0;j<n;j++){
      double a=-2*M_PI*k*j/n,c=cos(a),s=sin(a);
      re+=in[2*j]*c-in[2*j+1]*s;im+=in[2*j]*s+in[2*j+1]*c;
    }
    re/=sqrt(n);im/=sqrt(n);
    error+=(out[2*k]-re)*(out[2*k]-re)+(out[2*k+1]-im)*(out[2*k+1]-im);
    signal+=re*re+im*im;
  }
  double evm=sqrt(error/signal);
  /* Initial harness criterion for low-amplitude synthetic Q15 data. Record it
   * explicitly; this does not claim the original OAI test suite has passed. */
  if(!isfinite(evm)||evm>0.05){fprintf(stderr,"correctness failed: RMS EVM=%g\n",evm);return 5;}
  for(int j=0;j<100;j++)fn(index,in,out,1);
  double *samples=malloc(it*sizeof(double));if(!samples)return 4;
  double total=0;const int batch=32;
  for(int j=0;j<it;j++){
    uint64_t a=ns();
    for(int b=0;b<batch;b++)fn(index,in,out,1);
    uint64_t z=ns();samples[j]=(double)(z-a)/batch;total+=samples[j];
  }
  qsort(samples,it,sizeof(double),compare);
  printf("dft,%d,%d,%d,%d,%.6f,%.6f,%.6f,%.6f,%.8f,%d\n",n,round,it,batch,
    total/it/1000,samples[(it-1)/2]/1000,samples[(int)ceil(.95*it)-1]/1000,
    samples[(int)ceil(.99*it)-1]/1000,evm,out[0]);
  free(samples);free(in);free(out);dlclose(lib);return 0;
}
