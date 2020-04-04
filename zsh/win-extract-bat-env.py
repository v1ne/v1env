#!/usr/bin/env python

from __future__ import print_function
import subprocess
import sys

def main():
  batFile = sys.argv[1];

  linesOfCommand = lambda cmd: \
    subprocess.Popen(['cmd', '/c', cmd], stdout = subprocess.PIPE) \
    .communicate()[0] \
    .splitlines()

  oldEnvList = linesOfCommand('env')
  newEnvList = afterSep(linesOfCommand(batFile + '  & echo =================& env'),
    '=================')

  splitEntries = lambda env: filter(lambda entry: len(entry[0]) > 0,
    map(lambda line: line.split('=', 1), env))
  env = {name: (value, None) for (name, value) in splitEntries(oldEnvList)}
  newEnv = {name: value for (name, value) in splitEntries(newEnvList)}

  for name in newEnv.keys():
    if name in env:
      env[name] = (env[name][0], newEnv[name])
    else:
      env[name] = (None, newEnv[name])
    
  for name in env.keys():
    (oldValue, newValue) = env[name]
    if oldValue != newValue:
      if oldValue is None:
        quoteExport(name, newValue)
      else:
        handleDiff(name, oldValue, newValue)

def quoteExport(name, value):
  escapedValue = value.replace('\\', '\\\\').replace('"', '\\"',)
  print('export "{0}"="{1}"'.format(name, escapedValue))

def handleDiff(name, oldValue, newValue):
  if name == "PATH":
    oldPath = set(oldValue.split(':'));
    newPath = set(newValue.split(':'));
    
    if len(oldPath - newPath) > 0:
      raise ValueError("PATH elements were removed. This is unsupported.") 
    #quoteExport(name, '$' + name + ':' + ':'.join(list(newPath - oldPath)))
    quoteExport(name,  ':'.join(list(newPath - oldPath) +  ['$' + name]))
  else:
    print("Warning: overriding " + name, file=sys.stderr)
    quoteExport(name,  newValue)

def afterSep(lines, sep):
  gotSep = False
  for line in lines:
    if line == sep:
      gotSep = True
    if gotSep:
      yield line;

main()
