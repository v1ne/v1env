#!/bin/sh

sleep 0.5 # wait for gsettings to settle before updating vims
killall -USR1 vim &> /dev/null
killall -USR1 nvim &> /dev/null
