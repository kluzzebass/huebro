# huebro
Perl script for automatically handling/restoring Philips Hue bulbs after returning from a power failure.

Easy setup (on unix):

1. Edit the <code>BRIDGE</code> constant near the top of the script, and change the IP address to point at your own bridge.
2. Edit the <code>MAGIC_NUMBER</code> constant near the top of the script, specifying how many "Extended color light" bulbs need to be in the default power on state for the script to start restoring the state of all the lights. 3-4 seem like good numbers, but it depends entirely on your situation.
3. Press the link button on your Hue Bridge, and run <code>huebro.pl auth</code>, and the script should now have access to your bridge.
4. Run <code>huebro.pl -v check</code> to grab an initial snapshot of your lights. You should see some action on screen.
5. Set up a cron job that runs <code>huebro.pl check</code> periodically (once every minute seems ok).
6. Make some changes to your lights, and keep an eye on the <code>~/.huebro/huebro.log</code> file to see what's happening.

If you run into problems, use the <code>-v</code> and <code>-d</code> options, and try the <code>huebro.pl current</code> command to see what's going on. If you still can't figure it out, it's time to start reading the code.
