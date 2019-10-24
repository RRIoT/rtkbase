#!/bin/bash

###AUTHOR###
#Harry Dove-Robinson 5/8/2017
#harry@doverobinson.me
#https://gist.github.com/hdoverobinson
#https://github.com/hdoverobinson

###USAGE###
#This is a script used to configure u-blox GPS/GNSS modules from a text file generated by u-center.
#This allows for the possibility of simple in-situ u-blox receiver configuration on a Linux host. (u-center is Windows-only software.)
#It has been tested on the NEO-M8T, EVK-M8T and ZED-F9P modules with u-center 8.24, 19.03  and should work with any GPS receiver on the u-blox 8/M8 9/F9 firmware.
#The script takes its first argument as the path to a GPS device file and the second argument as the path to a .txt file used to configure the GPS.
#Example: ./ubxconfig.sh /dev/ttyACM0 NEO-M8T_10HZ_GNSS_SBAS.txt
#The receiver is first reset to factory defaults before it is configured from the text file. The configuration is then saved to all available flash.
#The configuration text file used should be one that is outputted from u-center (Tools -> GNSS Configuration...).
#The packages "dos2unix" and "bc" are required for this script to run.

###NOTES###
#The script will not run unless there is an exact match between the MON-VER string of the text file and the MON-VER output of the GPS receiver, except if
#the script detect 'MOD=ZED-F9P' or 'MOD=NEO-M8T-0' inside the MON-VER string and the text file.
#The MON-VER response is the longest parsed by the script, and it may take a few tries before the full message is able to be parsed.
#All other messages are sent up to 10 times before being permanently declared "NOT ACKNOWLEDGED". Note that this does not mean that it was explicitly rejected.
#If "ERROR - MESSAGE NOT ACKNOWLEDGED" is shown after 10 retries, then there is likely a problem with the contents of the configuration file or communication with the GPS receiver.
#It is expected behavior for some UBX messages to be rejected by the receiver. Try running the configuration file within u-center to see which ones.
#The STTY variable holds the stty configuration message that sets up the serial line for this script. It assumes a USB device able to run at 921600 baud.
#Other stty configuration messages can be loaded in with the output of "stty -F /dev/GPS0 -g" where "GPS0" is the character device file of the GPS.
#Currently this script cannot handle changes in the baudrate when used over an analog serial line. The GPS receiver should be connected to the host via USB.

export GPS=$1
export CONFIG=$2
export FORCE=$3
export STTY="406:0:18b7:8a30:3:1c:7f:8:4:2:64:0:11:13:1a:0:12:f:17:16:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0"
export RETRY_COUNT="10"
export TIMEOUT=".25s"
export UBX_ACK_ACK="b5620501"
export UBX_ACK_NAK="b5620500"
export UBX_PREAMBLE="B5 62"
export UBX_MON_VER_POLL="0A 04 00 00"
export UBX_CFG_CFG_REVERTDEFAULT="06 09 0D 00 FF FF 00 00 00 00 00 00 FF FF 00 00 17"
export UBX_CFG_CFG_SAVE="06 09 0D 00 00 00 00 00 FF FF 00 00 00 00 00 00 17"
ZED_F9P_MOD="00004d4f443d5a45442d4639500000000000000000000000000000000000"
NEO_M8T_0_MOD="00004d4f443d4e454f2d4d38542d30000000000000000000000000000000"

#counts number of sent messages up to the set number of retries
#anything sent into the counter should fail with exit code 1 and pass with exit code 0
send_counter ()
{
SENT_COUNTER=0
until [ $SENT_COUNTER == $RETRY_COUNT ] && echo "$(tput setaf 1)ERROR - MESSAGE NOT ACKNOWLEDGED$(tput sgr0)" && let ERROR_COUNTER=ERROR_COUNTER+1 || "$@"
do
let SENT_COUNTER=SENT_COUNTER+1
echo "NOT ACKNOWLEDGED"
if [ $SENT_COUNTER -ge 1 ] && [ $SENT_COUNTER -le $(expr $RETRY_COUNT - 1) ]
then
echo "RETRYING"
fi
done
}

#these needed to be functions so that ver_check can loop multiple times if it fails
file_mon_ver ()
{
#pulls MON-VER string from configuration file, finds only the hex and reformats for comparison
grep "MON-VER" $1 | sed 's/^.*-\s//' | xxd -r -p | xxd -p | tr -d '\n'
}
dev_mon_ver ()
{
#sends the MON-VER polling message, has larger timeout and set byte range because we expect a long response
echo "`ubx_chksum "$UBX_MON_VER_POLL"`" | xxd -r -p > $GPS && timeout 5s cat $GPS | xxd -p -l50000 | grep -m1 -a -A 10 "b5620a04" | tr -d '\n'
}

ver_check ()
{
dev_mon_ver=`dev_mon_ver`
file_mon_ver=`file_mon_ver $1`

if [[ ${dev_mon_ver} =~ .*${file_mon_ver}.* ]]
then
  echo "Version match!"
elif [[ ${dev_mon_ver} =~ .*${ZED_F9P_MOD}.* ]]  && [[ ${file_mon_ver} =~ .*${ZED_F9P_MOD}.* ]]
then
  echo "Firmware mismatch but product match!"
  echo "Product is ZED-F9P"
  if [[ ${FORCE} == '--force' ]]
  then
    echo "Trying to send the settings..."
  else
    echo "You can add --force on the commande line to send the settings anyway."
    return 1
  fi

elif [[ ${dev_mon_ver} =~ .*${NEO_M8T_0_MOD}.* ]]  && [[ ${file_mon_ver} =~ .*${NEO_M8T_0_MOD}.* ]]
then
  echo "Firmware mismatch but product match!"
  echo "Product is NEO-M8T-0"
  if [[ $FORCE == '--force' ]]
  then
    echo "Trying to send the settings..."
  else
    echo "You can add -FORCE on the commande line to send the settings"
    return 1
  fi

else
return 1
fi
}

send_ubx ()
{
echo "Sending UBX message: "$@""
#timeout is allowed in case no response is received
ubx_response=`timeout $TIMEOUT cat $GPS | xxd -p | grep -m1 -a -e "$UBX_ACK_ACK" -e "$UBX_ACK_NAK" & echo $2 | xxd -r -p > $GPS`
if [[ $ubx_response == *$UBX_ACK_ACK* ]]
then
echo "$(tput setaf 2)ACKNOWLEDGED$(tput sgr0)" && let ACK_COUNTER=ACK_COUNTER+1
elif [[ $ubx_response == *$UBX_ACK_NAK* ]]
then
echo "$(tput setaf 3)REJECTED$(tput sgr0)" && let NAK_COUNTER=NAK_COUNTER+1
else
return 1
fi
}

ubx_chksum ()
#############################################################################################################################
###Fletcher checksum calculator adapted from: http://www.aeronetworks.ca/2014/07/fletcher-checksum-calculator-in-bash.html###
#############################################################################################################################
{
SUM=0
FLETCHER=0
j=0

printf "$UBX_PREAMBLE "

for i in $1
do
 j=$(echo "ibase=16;$i" | bc)
 printf "%02X " "$j"
 SUM=$(echo "$SUM + $j" | bc)
 SUM=$(echo "$SUM%256" | bc)

 FLETCHER=$(echo "$FLETCHER + $SUM" | bc)
 FLETCHER=$(echo "$FLETCHER%256" | bc)
done

printf "%02X " "$SUM"
printf "%02X\n" "$FLETCHER"
}

main ()
{
#validate the GPS device and .txt file
if [[ -c $GPS ]] && [[ -f $CONFIG && -s $CONFIG && $CONFIG == *.txt ]]
then
#prepare serial port
stty -F $GPS $STTY
#remove windows carriage returns from config file
dos2unix $CONFIG

#version compatibility loop
echo "Checking compatibility..."
until ver_check $1
do
echo "Version mismatch! Checking again..."
done

ACK_COUNTER=0
NAK_COUNTER=0
ERROR_COUNTER=0

#configuration start
echo "Configuring u-blox GPS at $GPS from $1..."
echo "Resetting to factory defaults..."
send_counter send_ubx "UBX-CFG-CFG-REVERTDEFAULT" "$(ubx_chksum "$UBX_CFG_CFG_REVERTDEFAULT")"

echo "Restoring configuration from file..."
#loop through config file after MON-VER line and pass through ubx_chksum, send_ubx, and send_counter
while read -r line
do
send_counter send_ubx "`echo $line | sed 's/\s.*$//'`" "`ubx_chksum "$(echo $line | sed 's/^.*-\s//')"`"
done < <(tail -n+2 $1)

echo "Saving configuration to flash..."
send_counter send_ubx "UBX-CFG-CFG-SAVE" "$(ubx_chksum "$UBX_CFG_CFG_SAVE")"

echo -en "\n"
echo "Done!"

#print message stats
TOTAL=$(($ACK_COUNTER+$NAK_COUNTER+$ERROR_COUNTER))
echo -en "\n"
echo "----------------------------------------"
echo -en "\n"
echo "UBX MESSAGE STATISTICS:"
echo "$(tput setaf 2)ACKNOWLEDGED:$(tput sgr0) $ACK_COUNTER ($(echo "scale=2; $ACK_COUNTER / $TOTAL * 100" | bc | sed s/\\.[0-9]\\+//)%)"
echo "$(tput setaf 3)REJECTED:$(tput sgr0) $NAK_COUNTER ($(echo "scale=2; $NAK_COUNTER / $TOTAL * 100" | bc | sed s/\\.[0-9]\\+//)%)"
echo "$(tput setaf 1)ERRORS:$(tput sgr0) $ERROR_COUNTER ($(echo "scale=2; $ERROR_COUNTER / $TOTAL * 100" | bc | sed s/\\.[0-9]\\+//)%)"
echo "TOTAL SENT: $TOTAL"
echo -en "\n"

else
echo "Provide the GPS device as first argument and .txt file as second!"
return 1
fi
}

#check for dos2unix
if ! command -v dos2unix > /dev/null 2>&1
then
echo "Please install dos2unix!"
exit 2
fi

#check for bc
if ! command -v bc > /dev/null 2>&1
then
echo "Please install bc!"
exit 2
fi

#run
main $CONFIG

exit $ERROR_COUNTER
