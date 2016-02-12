module dsh.config;

import std.algorithm.searching,
       std.variant;

enum ElementType : int {
  STRING,
  INTEGER,
  UINTEGER,
  FLOAT,
  ARRAY,
  OBJECT,
  NULL
}

class ConfigElement {
  private Variant _value;
  public ElementType _type;

  this(Variant newValue, ElementType type) {
    _value = newValue;
    _type = type;
  }

  @property Variant value() {
    return _value;
  }

  @property ElementType type() {
    return _type;
  }
}

class DSHConfig {
  private ConfigElement[string] config;

  public void addNewConfig(T)(T value, string key, ElementType type) {
    Variant _value = value;
    config[key] = new ConfigElement(_value, type);
  }

  public void clearConfig(string key) {
    config[key] = null;
  }

  public Variant getConfig(string key) {
    if (configExists(key)) {
      return config[key].value;
    } else {
      Variant v = "";
      return v;
    }
  }

  private bool configExists(string key) {
    return config.keys.canFind(key);
  }
}
