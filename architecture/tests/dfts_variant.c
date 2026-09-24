#include <stddef.h>
#include <stdint.h>
#include KERNEL_HEADER
void VARIANT(const int16_t *a,const int16_t *b,const int16_t *tw,
             int16_t *y0,int16_t *y1,size_t n,int inverse)
{
  oai_rvv_bfly2_q15_i16(a,b,tw,y0,y1,n,inverse);
}
