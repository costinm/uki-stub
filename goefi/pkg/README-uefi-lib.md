# UEFI lib

This is a force merge from tamago go-boot (copied and modified as usbcore) and tinygo fork.

The tamago lib has better assembly and integration - but poor API coverage. 
The tinygo low level seems tied to tinygo and not as well implemented - but has pretty full
coverage of all services.

I got accessing the vars to work - the rest will be mechanical changes as needed.