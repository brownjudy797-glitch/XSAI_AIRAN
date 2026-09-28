// Test-only Gaussian APP; frozen from seed 314159 at 6 dB.
#include <math.h>
static const double app_edges[4] = {130,152,171,196};
static const double app_params[5][3][2] = {
  { {1.2054857853011869,1.2051078084076046}, {-0.013463565001549375,-0.015081716693126992}, {0.5280895335727542,0.5306841826277083} },
  { {1.0624447680526832,1.0576824549643018}, {-0.0067720354954906,-0.013039074758579482}, {0.3921679196551501,0.39280153770338255} },
  { {0.9888045309965047,0.9920702011673469}, {-0.011024847966282225,-0.01114586542394918}, {0.34003028268123825,0.33953097989091197} },
  { {0.9316862028885601,0.9320390905837409}, {-0.01342934346803346,-0.008938724023008894}, {0.3006605773427143,0.29793227702444414} },
  { {0.847780572979062,0.847843305612878}, {-0.009778653233311726,-0.006797883207159862}, {0.2501917917587295,0.25009872203179484} }
};
static const double app_temperature[4] = {1.0108069948828757,1.019031341745884,1.0022056030286013,0.9985224529732835};
static double app_logadd(double a, double b) {
  return fmax(a,b) + log1p(exp(-fabs(a-b)));
}
static void app_axis(double x, double mag, unsigned axis, double *sign, double *outer) {
  unsigned k=0;
  while (k<4 && mag>=app_edges[k]) ++k;
  const double levels[4]={.5,1.5,-.5,-1.5};
  double z[4];
  for (unsigned i=0;i<4;++i) {
    double d=x-app_params[k][0][axis]*levels[i]-app_params[k][1][axis];
    z[i]=-d*d/(2*app_params[k][2][axis]);
  }
  *sign=(app_logadd(z[0],z[1])-app_logadd(z[2],z[3]))*app_temperature[axis];
  *outer=(app_logadd(z[0],z[2])-app_logadd(z[1],z[3]))*app_temperature[axis+2];
}

