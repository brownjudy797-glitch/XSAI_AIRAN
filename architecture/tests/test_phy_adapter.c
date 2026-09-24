#include <stdint.h>
#include <stdio.h>
#include <limits.h>
#include "xsai_complex_adapter.h"
static uint32_t rng = 12345;
static int16_t sample(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return (int16_t)rng; }
int main(void)
{
  int16_t a[16], b[16]; int32_t re[8], im[8];
  for (int t=0;t<10001;t++) {
    for(int i=0;i<16;i++) { a[i]=t ? sample() : INT16_MIN; b[i]=t ? sample() : INT16_MIN; }
    for(int conj=0;conj<2;conj++) {
      for(int i=0;i<8;i++) re[i]=im[i]=123;
      bool handled=xsai_oai_try_cmul_q15x8(a,b,re,im,conj);
      if(handled != !!EXPECT_RVV) return 1;
      for(int i=0;i<8;i++) {
        if(!handled) { if(re[i]!=123 || im[i]!=123) return 2; continue; }
        int32_t ar=a[2*i], ai=a[2*i+1], br=b[2*i], bi=b[2*i+1];
        int32_t neg_bi=(int16_t)(-(int32_t)bi);
        uint32_t er=(uint32_t)((int64_t)ar*br+(int64_t)ai*(conj?bi:neg_bi));
        uint32_t ei=(uint32_t)((int64_t)ar*(conj?neg_bi:bi)+(int64_t)ai*br);
        if((uint32_t)re[i]!=er || (uint32_t)im[i]!=ei) return 3;
      }
    }
  }
  puts(EXPECT_RVV ? "PASS: RVV adapter scalar equivalence (20002 cases)" : "PASS: disabled adapter preserves outputs for caller fallback");
  return 0;
}
