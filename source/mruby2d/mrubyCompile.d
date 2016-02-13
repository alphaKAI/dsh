module mruby2d.mrubyCompile;
import mruby2d.mruby2d;

extern (C) {
  RProc *compileByPath(mrb_state* mrb, const char* path);
  RProc *compileByCode(mrb_state* mrb, const char* code);
}
