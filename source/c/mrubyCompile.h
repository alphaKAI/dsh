#ifndef MRUBY_COMPILE_H_MPE
#define MRUBY_COMPILE_H_MPE
struct RProc *compileByPath(mrb_state* mrb, const char* path);
struct RProc *compileByCode(mrb_state* mrb, const char* code);
#endif
