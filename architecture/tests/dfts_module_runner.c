#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <stdarg.h>
#include "common/utils/LOG/log.h"
#include "common/utils/T/T.h"
#include "dfts_sizes.h"
/* Logging/tracing host services only. No DFT implementation is mocked. */
static log_t test_log;
log_t *g_log=&test_log;
int T_stdout=1;
static int inactive[65536];
int *T_active=inactive;
volatile int *T_freelist_head;
T_cache_t *T_cache;
void logRecord_mt(const char *f,const char *fn,int l,int c,int level,const char *fmt,...)
{ (void)f;(void)fn;(void)l;(void)c;(void)level; va_list a;va_start(a,fmt);vfprintf(stderr,fmt,a);va_end(a); }
void exit_function(const char *f,const char *fn,const int l,const char *s,const int reason)
{fprintf(stderr,"OAI assertion %s:%d %s %s %d\n",f,l,fn,s,reason);abort();}
int32_t write_file_matlab(const char *f,const char *v,void *d,int n,int dec,unsigned int format,int multi)
{(void)f;(void)v;(void)d;(void)n;(void)dec;(void)format;(void)multi;fputs("Unexpected debug dump\n",stderr);abort();}
typedef void (*transform)(uint8_t,int16_t*,int16_t*,unsigned char);
static uint32_t rng;
static int16_t sample(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return (int16_t)rng;}
int main(int argc,char **argv)
{
  if(argc!=3 && argc!=5)return 2;
  void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
  if(!lib){fprintf(stderr,"%s\n",dlerror());return 3;}
  int (*init)(void)=(int (*)(void))dlsym(lib,"dfts_autoinit");
  if(!init || init()!=0)return 11;
  transform funcs[2]={(transform)dlsym(lib,"dft_implementation"),(transform)dlsym(lib,"idft_implementation")};
  if(!funcs[0]||!funcs[1])return 4;
  FILE *out=fopen(argv[2],"wb");if(!out)return 5;
  unsigned cases=0;
  for(int dir=0;dir<2;dir++) {
    if(argc==5 && dir!=atoi(argv[3]))continue;
    const int *sizes=dir?idft_sizes:dft_sizes;
    size_t count=dir?sizeof(idft_sizes)/sizeof(int):sizeof(dft_sizes)/sizeof(int);
    for(size_t idx=0;idx<count;idx++) {
      if(argc==5 && idx!=(size_t)atoi(argv[4]))continue;
      /* A's packed DFT variants operate on four parallel transforms. */
      size_t n=(size_t)sizes[idx]*(dir==0?dft_batch[idx]:1);
      size_t bytes=2*n*sizeof(int16_t);
      int16_t *input,*storage;
      if(posix_memalign((void**)&input,64,bytes+128)||posix_memalign((void**)&storage,64,bytes+128))return 6;
      int16_t *output=storage+32;
      for(int scale=0;scale<2;scale++)for(int pattern=0;pattern<4;pattern++){
        rng=0x12345678;
        memset(input,0,bytes+128);memset(storage,0x5a,bytes+128);
        for(size_t i=0;i<2*n;i++) {
          if(pattern==1)input[i]=i==0?1024:0;
          if(pattern==2)input[i]=sample()%1024;
          if(pattern==3)input[i]=sample();
        }
        printf("CASE %s %d scale=%d pattern=%d samples=%zu\n",dir?"IDFT":"DFT",sizes[idx],scale,pattern,2*n);fflush(stdout);
        funcs[dir]((uint8_t)idx,input,output,(unsigned char)scale);
        for(size_t i=0;i<64;i++)if(((unsigned char*)storage)[i]!=0x5a || ((unsigned char*)storage)[64+bytes+i]!=0x5a)return 7;
        if(pattern==0){size_t bad=0;for(size_t i=0;i<2*n;i++)bad+=output[i]!=0;
          if(bad)printf("ZERO_ANOMALY %s %d scale=%d nonzero=%zu\n",dir?"IDFT":"DFT",sizes[idx],scale,bad);}
        if(fwrite(output,1,bytes,out)!=bytes)return 9;
        cases++;
      }
      free(input);free(storage);
    }
  }
  if(fclose(out))return 10;
  printf("COMPLETED %u cases\n",cases);
  dlclose(lib);return 0;
}
