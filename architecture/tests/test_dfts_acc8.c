#include <stdint.h>
#include <stdio.h>
#include <limits.h>
#include "plugins/rvv_phy/include/oai_dfts_rvv.h"
static uint32_t state = 0x12345678;
static int16_t sample(void) {
  state ^= state << 13; state ^= state >> 17; state ^= state << 5;
  return (int16_t)state;
}
int main(void) {
  int16_t a[16][37], out[37];
  for (int trial = 0; trial < 1000; ++trial) {
    for (int j=0;j<16;++j) for(int k=0;k<37;++k) a[j][k]=sample();
    for (size_t done=0;done<37;) {
      size_t vl=__riscv_vsetvl_e16m1(37-done);
#define V(j) __riscv_vle16_v_i16m1(a[j]+done,vl)
      vint16m1_t r=oai_rvv_q15_acc8_i16(V(0),V(1),V(2),V(3),V(4),V(5),V(6),V(7),V(8),V(9),V(10),V(11),V(12),V(13),V(14),V(15),vl);
#undef V
      __riscv_vse16_v_i16m1(out+done,r,vl); done+=vl;
    }
    for(int k=0;k<37;++k) {
      uint32_t bits=0;
      for(int j=0;j<16;j+=4) {
        bits+=(uint32_t)((int32_t)a[j][k]*a[j+2][k]);
        bits+=(uint32_t)((int32_t)a[j+1][k]*a[j+3][k]);
      }
      int64_t sum=bits<=INT32_MAX ? (int64_t)bits : (int64_t)bits-4294967296LL;
      int64_t q=sum>=0 ? sum/32768 : -((-sum+32767)/32768);
      if(q>INT16_MAX) q=INT16_MAX;
      if(q<INT16_MIN) q=INT16_MIN;
      if(out[k]!=q) { fprintf(stderr,"Mismatch trial=%d lane=%d\n",trial,k);return 1; }
    }
  }
  puts("PASS: 37000 scalar Q15 accumulation comparisons, including vector tails");
  return 0;
}
