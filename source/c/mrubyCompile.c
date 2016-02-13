#include <stdio.h>
#include <string.h>

#include <mruby.h>
#include <mruby/proc.h>
#include <mruby/compile.h>

struct RProc* compileByPath(mrb_state* mrb, const char *path) {
  FILE* mrb_file;
  struct mrb_parser_state* p;
  struct RProc* proc;

  if ((mrb_file = fopen(path, "r")) == NULL) {
    return NULL;
  }

  p = mrb_parse_file(mrb, mrb_file, NULL);
  fclose(mrb_file);

  proc = mrb_generate_code(mrb, p);
  if (proc == NULL) {
    mrb_pool_close(p->pool);
    return NULL;
  }
  
  mrb_pool_close(p->pool);

  return proc;
}

struct RProc* compileByCode(mrb_state* mrb, const char *code) {
  struct mrb_parser_state* p;
  struct RProc* proc;
  struct mrbc_context* c;

  c = mrbc_context_new(mrb);
  p = mrb_parse_string(mrb, code, c);

  proc = mrb_generate_code(mrb, p);
  if (proc == NULL) {
    mrb_pool_close(p->pool);
    return NULL;
  }

  mrb_pool_close(p->pool);

  return proc;
}


