module mruby2d.mruby2d;
import std.string;

extern (C) {
  struct RProc;

  struct RObject;
  struct mrb_state {
    RObject *exc;
  }
  struct mrb_value { void* p; ubyte t; }; // 妥協
  mrb_state* mrb_open();
  void mrb_close(mrb_state*);
  mrb_value mrb_top_self(mrb_state *);
  mrb_value mrb_run(mrb_state*, RProc*, mrb_value);
  mrb_value mrb_load_string(mrb_state*, const char*);
  struct RString;
  RString* mrb_str_ptr(mrb_value s);
  alias long mrb_int;
  mrb_value mrb_funcall(mrb_state*, mrb_value, const char*, mrb_int,...);
  mrb_value mrb_obj_value(void*);
}

bool execMRubyString(mrb_state* mrb, string code) {
  mrb_load_string(mrb, code.toStringz);

  if (mrb.exc) {
    return false; 
  } else {
    return true;
  }
}
