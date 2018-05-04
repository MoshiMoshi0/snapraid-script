## How to use

* Copy or rename the example configuration file ```snapraid-script.psd1.example``` to ```snapraid-script.psd1```
* Configure ```snapraid-script.psd1``` as desired
    * If you enabled email notifications you need to run the script once to generate secure credential file ```snapraid-script.cred```. The script will send a test email to check if your credentials and smtp configuration are correct.

## Control flow

1. Try to load configuration file
2. If notifications are enabled, try to load credential file
    1. If credential file does not exist, prompt user to generate a new one
    2. Exit
3. Run ```diff```
    1. Parse output
    2. If number of deleted files exceeds configured ```Snapraid.Diff.DeleteThreshold```, abort the script
    3. If any changes are detected, run ```sync```
4. Run ```scrub``` with ```--plan``` and ```--older-than``` parameters from configuration file
5. Run ```status```
6. Send ```SUCCESS``` notification email

## Contribute

Issues and pull requests are welcome.