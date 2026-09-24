#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
void before(const int16_t*,const int16_t*,const int16_t*,int16_t*,int16_t*,size_t,int);
void after(const int16_t*,const int16_t*,const int16_t*,int16_t*,int16_t*,size_t,int);
static uint32_t state=7;
static int16_t sample(void) { state^=state<<13;state^=state>>17;state^=state<<5;return (int16_t)state; }
int main(void)
{
  const size_t sizes[]={0,1,7,8,9,16,31,64};
  int16_t a[128],b[128],tw[128],old0[128],old1[128],new0[128],new1[128];
  unsigned cases=0;
  for(unsigned t=0;t<1001;t++) {
    for(unsigned i=0;i<128;i++) {a[i]=t?sample():INT16_MIN;b[i]=t?sample():INT16_MAX;tw[i]=t?sample():INT16_MIN;}
    for(unsigned s=0;s<sizeof(sizes)/sizeof(sizes[0]);s++) for(int inv=0;inv<2;inv++) {
      memset(old0,0x5a,sizeof old0);memset(old1,0x5a,sizeof old1);
      memset(new0,0x5a,sizeof new0);memset(new1,0x5a,sizeof new1);
      before(a,b,tw,old0,old1,sizes[s],inv);after(a,b,tw,new0,new1,sizes[s],inv);
      if(memcmp(old0,new0,sizeof old0)||memcmp(old1,new1,sizeof old1)) {fprintf(stderr,"Mismatch t=%u n=%zu inv=%d\n",t,sizes[s],inv);return 1;}
      cases++;
    }
  }
  printf("PASS: %u forward/inverse butterfly migration cases\n",cases);
}
