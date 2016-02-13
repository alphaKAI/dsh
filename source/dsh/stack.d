module dsh.stack;
import std.exception,
       std.array,
       std.range;
import core.memory;

struct Stack(T) {
  private T* stack;
  private immutable defaultLength = 1024;
  private size_t len;
  private size_t realLen;
  private size_t cursor;
  public bool autoExtend = true;

  void init(size_t _len = 0) {
    if (_len) {
      len = _len;
    } else {
      len = defaultLength;
    }

    stack = cast(T*)GC.malloc(T.sizeof * len, GC.BlkAttr.NO_SCAN | GC.BlkAttr.APPENDABLE);
  }
 
  private void extend(size_t order = 1024) {
    size_t r = GC.extend(stack, order * T.sizeof, (order * 2) * T.sizeof);

    if (r != 0) {
      len = r / T.sizeof;
    } else {
      GC.realloc(stack, T.sizeof * 1024, GC.BlkAttr.NO_SCAN | GC.BlkAttr.APPENDABLE);
    }
  }

  @property size_t length() {
    return len;
  }

  void push(T newValue) {
    if ((len - (len / 10) < cursor && autoExtend) || (cursor == (len - 1) && !autoExtend)) {
      extend;
    }

    stack[cursor++] = newValue;
    realLen++;
  }

  @property T pop() {
    T t = stack[--cursor];
    realLen--;

    return t;
  }

  @property bool empty() {
    return realLen == 0;
  }
}

struct Stack2(T) {
  private T[] stack;

  void push(T newValue) {
    stack ~= newValue;
  }

  @property T pop() {
    T t = stack[$ - 1];
    stack = stack[0..$ - 1];
    return t;
  }

  @property bool empty() {
    return stack.empty;
  }
}
