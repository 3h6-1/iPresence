<h1 align="center"> iPresence </h1>
A jailbreak daemon that runs a mini Discord client in the background to set your status as your iPod/Music app activty with the help of a Springboard tweak
<hr>
<h3> Version </h3>
This is currently the very first version. Expect bugs.
<h3> Requirements </h3>
Minumum IOS version of 5.0, jailbreak, armv7 or armv7s 32-bit processor
<h3> Installation </h3>
First install the ipa and set your token, then the deb packages by copying them to /var/root/Media/Cydia/AutoInstall/. Then, restart your device
<h3> Build </h3>
Use clang to compile the helper and the daemon, and command line xCode for the ipa. You can find the commands to build commented in the main classes for each application. xCode version is 5.1.1