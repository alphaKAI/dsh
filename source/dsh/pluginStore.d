module dsh.pluginStore;
import dsh.plugin;
import std.regex;

class PluginStore {
  private Plugin[string] plugins;

  this() {
  
  }
  
  @property string[] getPlugins() {
    return plugins.keys;
  }
}
