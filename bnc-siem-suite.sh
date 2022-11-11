#!/bin/bash

#
# bnc-siem-suite.sh
# by Kevin Branch (kevin@branchnetconsulting.com)
#
# This script is a dual-role script, both running through a series of checks to determine if there is need to install the SIEM packages and installing the SIEM packages
# if warranted.
#
# Deployment will install Wazuh agent and Wazuh-integrated Osquery on Ubuntu, CentOS, and Amazon Linux systems.
# After preserving the working Wazuh agent registration key if present, Wazuh/OSSEC agent and/or Osquery are completely purged and then reinstalled,
# with an option to skip Osquery.
# The Wazuh agent self registration process is included, but will be skipped if an existing working registration can be recycled.
# Agent name and group names must match exactly for registration to be recycled.  This will keep the same agent id associated with the agent.
#
# If any of the listed test families fail, the SIEM packages will be (re)installed.
#
# If the call to this script is deemed broken, or either the Wazuh Manager connect port or registration port are unresponsive to a probe, an exit code of 2 will be returned.
#
# The default exit code is 0.
#
# Is the agent presently really connected to the Wazuh manager?
# Is the agent connected to the right manager?
# Is the agent currently a member of all intended Wazuh agent groups?
# Is the target version of Wazuh agent installed?
# Is the target version of Osquery installed and running?
#
# Parameters:
#
# -WazuhMgr         IP or FQDN of the Wazuh manager for ongoing agent connections. (Required)
# -WazuhRegMgr      IP or FQDN of the Wazuh manager for agent registration connection (defaults to $WazuhMgr if not specified)
# -WazuhRegPass     Required: password for registration with Wazuh manager (put in quotes).
# -WazuhVer         Full version of Wazuh agent to confirm and/or install, like "3.13.2".
# -WazuhSrc         Static download path to fetch Wazuh agent installer.  Overrides WazuhVer value.
# -WazuhAgentName   Name under which to register this agent in place of locally detected Linux host name
# -WazuhGroups      Comma separated list of optional extra Wazuh agent groups to member this agent.  No spaces.  Put whole list in quotes.  Groups must already exist.
#                   Use "" to expect zero extra groups.
#                   If not specified, agent group membership will not be checked at all.
#                   Do not include "linux" or "linux-local" group as these are autodetected and will dynamically be inserted as groups.
#                   Also, do not include "osquery" as this will automatically be included unless SkipOsquery is set to "1"
# -OsqueryVer       Full version of Osquery to validate and/or install, like "4.2.0" (always N.N.N format) (Required unless -SkipOsquery specified).
# -OsquerySrc       Static download path to fetch Osquery agent installer.  Overrides OsqueryVer value.
# -SkipOsquery      Set this flag to skip examination and/or installation of Osquery.  If the script determines that installation is warranted, this flag will result in Osquery being removed if present.
#                   Osquery is installed by default.
# -LBprobe          Load Balancer paramert that initiates further testing to ensure the Wazuh Manager auth daemon is listining.
# -Install          Skip all checks and force installation
# -Uninstall        Uninstall Wazuh agent and sub-agents
# -CheckOnly        Only run checks to see if installation is current or in need of deployment
# -Debug            Show debug output
# -help             Show command syntax
#
# Sample way to fetch and use this script:
#
# curl https://raw.githubusercontent.com/branchnetconsulting/wazuh-tools/master/bnc-siem-suite.sh > bnc-siem-suite.sh
# chmod 700 bnc-siem-suite.sh
#
# Example minimal usage:
#
# ./bnc-siem-suite.sh -WazuhMgr siem.company.com -WazuhRegPass "self-reg-pw" -WazuhVer 3.13.2 -OsqueryVer 4.4.0
#
# The above would (re)install the latest stable Wazuh agent and Osquery, if the checks determine it is warranted.
# It would also self-register with the specified Wazuh manager using the specified password, unless an existing working registration can be kept.
# The agent would be registered with agent groups "linux,linux-local,osquery,osquery-local" or "linux,linux-local,osquery,osquery-local" depending on if this is an rpm or deb system.
#

function show_usage() {
   LBLU='\033[1;34m'
   NC='\033[0m'
   printf "\nCommand syntax:\n   $0 \n      -WazuhMgr ${LBLU}WAZUH_MANAGER${NC}\n      [-WazuhRegMgr ${LBLU}WAZUH_REGISTRATION_MANAGER${NC}]\n      -WazuhRegPass \"${LBLU}WAZUH_REGISTRATION_PASSWORD${NC}\"\n      {-WazuhVer ${LBLU}WAZUH_VERSION${NC} | -WazuhSrc ${LBLU}WAZUH_AGENT_DOWNLOAD_URL${NC}}\n      [-WazuhAgentName ${LBLU}WAZUH_AGENT_NAME_OVERRIDE${NC}]\n      [-WazuhGroups {${LBLU}LIST_OF_EXTRA_GROUPS${NC} | \"\"}]\n      {-OsqueryVer ${LBLU}OSQUERY_VERSION${NC} | -OsquerySrc ${LBLU}OSQUERY_DOWNLOAD_URL${NC} | -SkipOsquery}\n      [-Install]\n      [-Uninstall]\n      [-CheckOnly]\n      [-Debug]\n      [-help]\n\n"
   printf "Example:\n   $0 -WazuhMgr ${LBLU}siem.company.org${NC} -WazuhRegPass ${LBLU}\"h58fg3FS###12\"${NC} -WazuhVer ${LBLU}3.13.1${NC} -OsqueryVer ${LBLU}4.4.0${NC} -WazuhGroups ${LBLU}finance,denver${NC}\n\n"
   exit 2
}

function check_value() {
   if [[ "$1" == "" || "$1" == "-"* ]]; then
   	show_usage
   fi
}

# Named parameter optional default values
WazuhMgr=
WazuhRegMgr=
WazuhRegPass=
WazuhVer=
WazuhSrc=
WazuhAgentName=
WazuhGroups="#NOGROUP#"
OsqueryVer=
OsquerySrc=
SkipOsquery=0
LBprobe=0
CheckOnly=0
Install=0
Uninstall=0
Debug=0

while [ "$1" != "" ]; do
   case $1 in
      -WazuhMgr )     shift
                      check_value $1
                      WazuhMgr=$1
                      ;;
      -WazuhRegMgr )  shift
                      check_value $1
                      WazuhRegMgr=$1
                      ;;
      -WazuhRegPass ) shift
                      check_value $1
                      WazuhRegPass=$1
                      ;;
      -WazuhVer )     shift
                      check_value $1
                      WazuhVer="$1"
                      ;;
      -WazuhSrc )     shift
                      check_value $1
                      WazuhSrc="$1"
                      ;;
      -WazuhAgentName ) shift
                      check_value $1
                      WazuhAgentName="$1"
                                          ;;
      -WazuhGroups )  if [[ "$2" == "" ]]; then
                         shift
                         WazuhGroups=""
                      elif [[ "$2" == "-"* ]]; then
                         WazuhGroups=""
                      else
                         shift
                         WazuhGroups="$1"
                      fi
                      ;;
      -OsqueryVer )   shift
                      check_value $1
                      OsqueryVer="$1"
                      ;;
      -OsquerySrc )   shift
                      check_value $1
                      OsquerySrc="$1"
                      ;;
      -SkipOsquery )  # no shift
                      SkipOsquery=1
                      ;;
      -LBprobe )      # no shift
                      LBprobe=1
                      ;;
      -CheckOnly )    # no shift
                      CheckOnly=1
                      ;;
      -Install )      # no shift
                      Install=1
                      ;;
      -Uninstall )  # no shift
                      Uninstall=1
                      ;;
      -Debug )        # no shift
                      Debug=1
                      ;;
      -help )         show_usage
                      ;;
      * )             show_usage
   esac
   shift
done

# Function for probing the Wazuh agent connection and Wazuh agent self-registration ports on the manager(s).
function tprobe() {
        if [ $Debug == 1 ]; then echo "Preparing to probe $1 on port $2..."; fi
        if [[ `echo $1 | grep -P "^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$"` ]]; then
                if [ $Debug == 1 ]; then echo "$1 appears to be an IP number."; fi
                tpr_ip=$1
        else
                if [ $Debug == 1 ]; then echo "Looking up IP for host $1..."; fi
                tpr_ip=`getent ahostsv4 $1 | awk '{ print $1 }' | head -n1`
        fi
        if [ "$tpr_ip" == "" ]; then
                if [ $Debug == 1 ]; then echo "*** Failed to find IP for $1."; fi
                exit 2
        fi
        if [ $Debug == 1 ]; then echo "Probing $tpr_ip:$2..."; fi
        echo > /dev/tcp/$tpr_ip/$2 &
        sleep 2
        if [[ `ps auxw | awk '{print $2}' | egrep "^$!"` ]]; then
                if [ $Debug = 1 ]; then echo "*** Failed to get response from $1 on tcp/$2."; fi
                kill $!
                exit 2
        fi
        if [ $Debug == 1 ]; then echo "Success!"; fi
}

function writeMergeScript() {
        # merge-wazuh-conf.sh version 1.0
        mkdir /var/ossec/custbin 2> /dev/null
        EncodedMergeScript="IwojIG1lcmdlLXdhenVoLWNvbmYuc2gKIyB2ZXJzaW9uIDEuMAojIGJ5IEtldmluIEJyYW5jaCAoQnJhbmNoIE5ldHdvcmsgQ29uc3VsdGluZywgTExDKQojCiMgVGhpcyBidWlsZHMgYW5kIGFwcGxpZXMgYSBmcmVzaCAvdmFyL29zc2VjL2V0Yy9vc3NlYy5jb25mIGZyb20gYSBtZXJnZSBvZiBhbGwgL3Zhci9vc3NlYy9ldGMvY29uZi5kLyouY29uZiBmaWxlcywgd2l0aCBhdXRvbWF0aWMgcmV2ZXJ0aW9uIHRvIHRoZSBwcmV2aW91cyBvc3NlYy5jb25mIGluIHRoZSBldmVudCB0aGF0IFdhenVoIEFnZW50IGZhaWxzIHRvIHJlc3RhcnQgb3IgcmVjb25uZWN0IHdpdGggdGhlIG5ld2VyIG1lcmdlZCB2ZXJzaW9uIG9mIG9zc2VjLmNvbmYuCiMgSXQgaXMgaW50ZW5kZWQgdG8gYmUgcnVuIGF1dG9tYXRpY2FsbHkgYnkgV2F6dWggQWdlbnQgaXRzZWxmIHZpYSBhIGxvY2FsbHkgZGVmaW5lZCBjb21tYW5kLXR5cGUgbG9jYWxmaWxlIHNlY3Rpb24gaW52b2tpbmcgaXQgYXQgb3NzZWMtYWdlbnQgY3VzdGJpbi9tZXJnZS13YXp1aC1jb25mLnNoLgojIFRoaXMgaXMgcGFydCBvZiBhY2NvbW9kYXRpbmcgdGhlIHVzZSBvZiBjdXN0b20gV1BLcyB0byBzZWN1cmVseSBkaXN0cmlidXRlIGFuZC9vciBpbnZva2UgbmV3IHNjcmlwdHMgYW5kIHRvIGRpc3RyaWJ1dGUgYW5kIGFwcGx5IG5ldyBjb25maWcgc2VjdGlvbnMgdG8gYmUgbWVyZ2VkIGludG8gb3NzZWMuY29uZiwgZXNwZWNpYWxseSBvbmVzIGludm9sdmluZyBmb3JtZXJseSAicmVtb3RlIiBjb21tYW5kcy4KIwojIFRoaXMgc2NyaXB0IHNob3VsZCBiZSBsb2NhdGVkIGFuZCBleGVjdXRlZCBpbiAvdmFyL29zc2VjL2V0Yy9jdXN0YmluL21lcmdlLXdhenVoLWNvbmYuc2guCiMgVGhlIGZvbGxvd2luZyBtdXN0IGJlIHBhcnQgb2YgL3Zhci9vc3NlYy9ldGMvb3NzZWMuY29uZiB0byBlbnN1cmUgdGhpcyBzY3JpcHQgaXMgcnVuIGRhaWx5IGFuZCBhdCBlYWNoIGFnZW50IHJlc3RhcnQuCiMKIyA8b3NzZWNfY29uZmlnPgojICAgPGxvY2FsZmlsZT4KIyAgICAgIDxsb2dfZm9ybWF0PmNvbW1hbmQ8L2xvZ19mb3JtYXQ+CiMgICAgICA8YWxpYXM+bWVyZ2Utd2F6dWgtY29uZjwvYWxpYXM+CiMgICAgICA8Y29tbWFuZD5jdXN0YmluL21lcmdlLXdhenVoLWNvbmYuc2g8L2NvbW1hbmQ+CiMgICAgICA8ZnJlcXVlbmN5Pjg2NDAwPC9mcmVxdWVuY3k+CiMgICA8L2xvY2FsZmlsZT4KIyA8L29zc2VjX2NvbmZpZz4KIwojIExvZyBlbnRyaWVzIHdyaXR0ZW4gdG8gQXBwbGljYXRpb24gbG9nIHdpdGggc291cmNlIEJOQy1TSUVNLUluc3RydW1lbnRhdGlvbjoKIwojICJJbmZvIC0gbWVyZ2Utd2F6dWgtY29uZi5zaCBhcHBseWluZyBuZXcgbWVyZ2VkIG9zc2VjLmNvbmYgYW5kIHJlc3RhcnRpbmcgV2F6dWggYWdlbnQuLi4iCiMgIkVycm9yIC0gbWVyZ2Utd2F6dWgtY29uZi5zaCBuZXcgb3NzZWMuY29uZiBhcHBlYXJzIHRvIHByZXZlbnQgV2F6dWggQWdlbnQgZnJvbSBzdGFydGluZy4gIFJldmVydGluZyBhbmQgcmVzdGFydGluZy4uLiIKIyAiSW5mbyAtIG1lcmdlLXdhenVoLWNvbmYuc2ggcmV2ZXJ0ZWQgb3NzZWMuY29uZiBhbmQgV2F6dWggYWdlbnQgc3VjY2Vzc2Z1bGx5IHJlc3RhcnRlZC4uLiIKIyAiRXJyb3IgLSBtZXJnZS13YXp1aC1jb25mLnNoIHJldmVydGVkIG9zc2VjLmNvbmYgYW5kIFdhenVoIGFnZW50IHN0aWxsIGZhaWxlZCB0byBzdGFydC4iCiMgIkluZm8gLSBtZXJnZS13YXp1aC1jb25mLnNoIGV4aXRlZCBkdWUgdG8gYSBwcmV2aW91cyBmYWlsZWQgb3NzZWMuY29uZiByZW1lcmdlIGF0dGVtcHQgbGVzcyB0aGFuIGFuIGhvdXIgYWdvLiIKIyAiSW5mbyAtIG1lcmdlLXdhenVoLWNvbmYuc2ggZm91bmQgb3NzZWMuY29uZiB1cCB0byBkYXRlIHdpdGggY29uZi5kLiIKIwoKIyBJZiBXYXp1aCBhZ2VudCBjb25mLmQgZGlyZWN0b3J5IGlzIG5vdCB5ZXQgcHJlc2VudCwgdGhlbiBjcmVhdGUgaXQgYW5kIHBvcHVsYXRlIGl0IHdpdGggYSAwMDAtYmFzZS5jb25mIGNvcGllZCBmcm9tIGN1cnJlbnQgb3NzZWMuY29uZiBmaWxlLgoKaWYgIFsgISAtZCAvdmFyL29zc2VjL2V0Yy9jb25mLmQgXTsgdGhlbgogICAgbWtkaXIgL3Zhci9vc3NlYy9ldGMvY29uZi5kIDI+IC9kZXYvbnVsbAogICAgY2hvd24gLVIgcm9vdDp3YXp1aCAvdmFyL29zc2VjL2V0Yy9jb25mLmQgMj4gL2Rldi9udWxsCiAgICBjcCAvdmFyL29zc2VjL2V0Yy9vc3NlYy5jb25mIC92YXIvb3NzZWMvZXRjL2NvbmYuZC8wMDAtYmFzZS5jb25mIDI+IC9kZXYvbnVsbAogICAgIyBJZiB0aGUgbmV3bHkgZ2VuZXJhdGVkIDAwMC1iYXNlLmNvbmYgKGZyb20gb2xkIG9zc2VjLmNvbmYpIGlzIG1pc3NpbmcgdGhlIG1lcmdlLXdhenVoLWNvbmYgY29tbWFuZCBzZWN0aW9uLCB0aGVuIGFwcGVuZCBpdCBub3cuCiAgICBpZiBbWyAhIGBncmVwIG1lcmdlLXdhenVoLWNvbmYgL3Zhci9vc3NlYy9ldGMvY29uZi5kLzAwMC1iYXNlLmNvbmYgMj4gL2Rldi9udWxsYCBdXTsgdGhlbgogICAgICAgIGVjaG8gIgo8b3NzZWNfY29uZmlnPgogICAgPGxvY2FsZmlsZT4KICAgICAgIDxsb2dfZm9ybWF0PmNvbW1hbmQ8L2xvZ19mb3JtYXQ+CiAgICAgICA8YWxpYXM+bWVyZ2Utd2F6dWgtY29uZjwvYWxpYXM+CiAgICAgICA8Y29tbWFuZD4vdXNyL2xvY2FsL2Jpbi9tZXJnZS13YXp1aC1jb25mLnNoPC9jb21tYW5kPgogICAgICAgPGZyZXF1ZW5jeT44NjQwMDwvZnJlcXVlbmN5PgogICAgPC9sb2NhbGZpbGU+Cjwvb3NzZWNfY29uZmlnPgogICAgICAgICIgPj4gL3Zhci9vc3NlYy9ldGMvY29uZi5kLzAwMC1iYXNlLmNvbmYKICAgIGZpCmZpCgojIElmIHRoZXJlIHdhcyBhIGZhaWxlZCBvc3NlYy5jb25mIHJlbWVyZ2UgYXR0ZW1wdCBsZXNzIHRoYW4gYW4gaG91ciBhZ28gdGhlbiBiYWlsIG91dCAoZmFpbGVkIGFzIGluIFdhenVoIGFnZW50IHdvdWxkIG5vdCBzdGFydCB1c2luZyBsYXRlc3QgbWVyZ2VkIG9zc2VjLmNvbmYpCiMgVGhpcyBpcyB0byBwcmV2ZW50IGFuIGluZmluaXRlIGxvb3Agb2YgcmVtZXJnaW5nLCByZXN0YXJ0aW5nLCBmYWlsaW5nLCByZXZlcnRpbmcsIGFuZCByZXN0YXJ0aW5nIGFnYWluLCBjYXVzZWQgYnkgYmFkIG1hdGVyaWFsIGluIGEgY29uZi5kIGZpbGUuCmlmIFsgLWYgL3Zhci9vc3NlYy9ldGMvb3NzZWMuY29uZi1CQUQgXSAmJiBbICQoKGBkYXRlICslc2AgLSBgc3RhdCAtYyAlWSAvdmFyL29zc2VjL2V0Yy9vc3NlYy5jb25mLUJBRGApKSAtbHQgMzYwMCBdO3RoZW4KICAgIGxvZ2dlciAtdCAiQk5DLVNJRU0tSW5zdHJ1bWVudGF0aW9uIiAiSW5mbyAtIG1lcmdlLXdhenVoLWNvbmYuc2ggZXhpdGVkIGR1ZSB0byBhIHByZXZpb3VzIGZhaWxlZCBvc3NlYy5jb25mIHJlbWVyZ2UgYXR0ZW1wdCBsZXNzIHRoYW4gYW4gaG91ciBhZ28uIgogICAgZXhpdApmaQoKIyBNZXJnZSBjb25mLmQvKi5jb25mIGludG8gY29uZi5kL2NvbmZpZy5tZXJnZWQKZmlsZXM9YGxzIC92YXIvb3NzZWMvZXRjL2NvbmYuZC8qLmNvbmZgCnJtIC92YXIvb3NzZWMvZXRjL2NvbmYuZC9jb25maWcubWVyZ2VkIDI+IC9kZXYvbnVsbApjYXQgJGZpbGVzID4gL3Zhci9vc3NlYy9ldGMvY29uZi5kL2NvbmZpZy5tZXJnZWQgMj4gL2Rldi9udWxsCgojIElmIHRoZSByZWJ1aWx0IGNvbmZpZy5tZXJnZWQgZmlsZSBpcyB0aGUgc2FtZSAoYnkgTUQ1IGhhc2gpIGFzIHRoZSBtYWluIG9zc2VjLmNvbmYgdGhlbiB0aGVyZSBpcyBub3RoaW5nIG1vcmUgdG8gZG8uCmhhc2gxPWBtZDVzdW0gL3Zhci9vc3NlYy9ldGMvY29uZi5kL2NvbmZpZy5tZXJnZWQgfCBhd2sgJ3twcmludCAkMX0nYApoYXNoMj1gbWQ1c3VtIC92YXIvb3NzZWMvZXRjL29zc2VjLmNvbmYgfCBhd2sgJ3twcmludCAkMX0nYAppZiBbICIkaGFzaDEiID0gIiRoYXNoMiIgXTsgdGhlbgogICAgI2VjaG8gIm9zc2VjLmNvbmYgaXMgdXAgdG8gZGF0ZSIKICAgIGxvZ2dlciAtdCAiQk5DLVNJRU0tSW5zdHJ1bWVudGF0aW9uIiAiSW5mbyAtIG1lcmdlLXdhenVoLWNvbmYuc2ggZm91bmQgb3NzZWMuY29uZiB1cCB0byBkYXRlIHdpdGggY29uZi5kLiIKCiMgSG93ZXZlciBpZiBjb25maWcubWVyZ2VkIGlzIGRpZmZlcmVudCB0aGFuIG9zc2VjLmNvbmYsIHRoZW4gYmFjayB1cCBvc3NlYy5jb25mLCByZXBsYWNlIGl0IHdpdGggY29uZmlnLm1lcmdlZCwgYW5kIHJlc3RhcnQgV2F6dWggQWdlbnQgc2VydmljZQplbHNlCiAgICAjIGVjaG8gIm9zc2VjLmNvbmYgcmVidWlsdCBmcm9tIG1lcmdlIG9mIGNvbmYuZCBmaWxlcyIKICAgIGxvZ2dlciAtdCAiQk5DLVNJRU0tSW5zdHJ1bWVudGF0aW9uIiAiSW5mbyAtIG1lcmdlLXdhenVoLWNvbmYuc2ggYXBwbHlpbmcgbmV3IG1lcmdlZCBvc3NlYy5jb25mIGFuZCByZXN0YXJ0aW5nIFdhenVoIGFnZW50Li4uIgogICAgY3AgLXByIC92YXIvb3NzZWMvZXRjL29zc2VjLmNvbmYgL3Zhci9vc3NlYy9ldGMvb3NzZWMuY29uZi1CQUNLVVAgMj4gL2Rldi9udWxsCiAgICBjcCAtcHIgL3Zhci9vc3NlYy9ldGMvY29uZi5kL2NvbmZpZy5tZXJnZWQgL3Zhci9vc3NlYy9ldGMvb3NzZWMuY29uZiAyPiAvZGV2L251bGwKICAgIGNob3duIHJvb3Q6d2F6dWggL3Zhci9vc3NlYy9ldGMvb3NzZWMuY29uZiAyPiAvZGV2L251bGwKICAgIHN5c3RlbWN0bCBzdG9wIHdhenVoLWFnZW50IDI+IC9kZXYvbnVsbAogICAgc3lzdGVtY3RsIHN0YXJ0IHdhenVoLWFnZW50IDI+IC9kZXYvbnVsbAogICAgc2xlZXAgMTAKICAgICMgSWYgYWZ0ZXIgcmVwbGFjaW5nIG9zc2VjLmNvbmYgYW5kIHJlc3RhcnRpbmcsIHRoZSBXYXp1aCBBZ2VudCBmYWlscyB0byBzdGFydCwgdGhlbiByZXZlcnQgdG8gdGhlIGJhY2tlZCB1cCBvc3NlYy5jb25mLCByZXN0YXJ0LCBhbmQgaG9wZWZ1bGx5IHJlY292ZXJpbmcgdGhlIHNlcnZpY2UuCiAgICBpZiBbWyAhIGBwZ3JlcCAteCAid2F6dWgtYWdlbnRkImAgXV0gfHwgW1sgISBgbmV0c3RhdCAtbmF0IHwgZ3JlcCAxNTE0IHwgYXdrIC1GJzonICd7cHJpbnQgJDN9J2AgPX4gXjE1MTRbXlxkXStFU1RBQkxJU0hFRCBdXTsgdGhlbgogICAgICAgICMgZWNobyAiV2F6dWggQWdlbnQgc2VydmljZSBmYWlsZWQgdG8gc3RhcnQgd2l0aCB0aGUgbmV3bHkgbWVyZ2VkIG9zc2VjLmNvbmYhICBSZXZlcnRpbmcgdG8gYmFja2VkIHVwIG9zc2VjLmNvbmYuLi4iCiAgICAgICAgbG9nZ2VyIC10ICJCTkMtU0lFTS1JbnN0cnVtZW50YXRpb24iICJFcnJvciAtIG1lcmdlLXdhenVoLWNvbmYuc2ggbmV3IG9zc2VjLmNvbmYgYXBwZWFycyB0byBwcmV2ZW50IFdhenVoIEFnZW50IGZyb20gc3RhcnRpbmcuICBSZXZlcnRpbmcgYW5kIHJlc3RhcnRpbmcuLi4iCiAgICAgICAgbXYgL3Zhci9vc3NlYy9ldGMvb3NzZWMuY29uZiAvdmFyL29zc2VjL2V0Yy9vc3NlYy5jb25mLUJBRCAyPiAvZGV2L251bGwKICAgICAgICBtdiAvdmFyL29zc2VjL2V0Yy9vc3NlYy5jb25mLUJBQ0tVUCAvdmFyL29zc2VjL2V0Yy9vc3NlYy5jb25mIDI+IC9kZXYvbnVsbAogICAgICAgIGNob3duIHJvb3Q6d2F6dWggL3Zhci9vc3NlYy9ldGMvb3NzZWMuY29uZiAyPiAvZGV2L251bGwKICAgICAgICBzeXN0ZW1jdGwgc3RvcCB3YXp1aC1hZ2VudCAyPiAvZGV2L251bGwKICAgICAgICBzeXN0ZW1jdGwgc3RhcnQgd2F6dWgtYWdlbnQgMj4gL2Rldi9udWxsCiAgICAgICAgc2xlZXAgMTAKICAgICAgICAjIEluZGljYXRlIGlmIHRoZSBzZXJ2aWNlIHdhcyBzdWNjZXNzZnVsbHkgcmVjb3ZlcmVkIGJ5IHJldmVydGluZyBvc3NlYy5jb25mLgogICAgICAgIGlmIFtbIGBwZ3JlcCAteCAid2F6dWgtYWdlbnRkImAgXV0gJiYgW1sgYG5ldHN0YXQgLW5hdCB8IGdyZXAgMTUxNCB8IGF3ayAtRic6JyAne3ByaW50ICQzfSdgID1+IF4xNTE0W15cZF0rRVNUQUJMSVNIRUQgXV07IHRoZW4KICAgICAgICAgICAgICAgICMgZWNobyAiV2F6dWggQWdlbnQgc3VjY2Vzc2Z1bGx5IHJ1bm5pbmcgd2l0aCByZXZlcnRlZCBvc3NlYy5jb25mLiIKICAgICAgICAgICAgICAgIGxvZ2dlciAtdCAiQk5DLVNJRU0tSW5zdHJ1bWVudGF0aW9uIiAiSW5mbyAtIG1lcmdlLXdhenVoLWNvbmYuc2ggcmV2ZXJ0ZWQgb3NzZWMuY29uZiBhbmQgV2F6dWggYWdlbnQgc3VjY2Vzc2Z1bGx5IHJlc3RhcnRlZC4uLiIKICAgICAgICBlbHNlCiAgICAgICAgICAgICAgICAjIGVjaG8gIldhenVoIEFnZW50IGZhaWxzIHRvIHN0YXJ0IHdpdGggcmV2ZXJ0ZWQgb3NzZWMuY29uZi4gIE1hbnVhbCBpbnRlcnZlbnRpb24gcmVxdWlyZWQuIgogICAgICAgICAgICAgICAgbG9nZ2VyIC10ICJCTkMtU0lFTS1JbnN0cnVtZW50YXRpb24iICJFcnJvciAtIG1lcmdlLXdhenVoLWNvbmYuc2ggcmV2ZXJ0ZWQgb3NzZWMuY29uZiBhbmQgV2F6dWggYWdlbnQgc3RpbGwgZmFpbGVkIHRvIHN0YXJ0LiIKICAgICAgICBmaQogICAgZmkKZmkK"
        echo $EncodedMergeScript | base64 -d > /var/ossec/custbin/merge-wazuh-conf.sh
        chmod +rx /var/ossec/custbin/merge-wazuh-conf.sh 2> /dev/null
        # To generate a fresh base64 encoded version of merge-wazuh-conf.sh:
        #    wget -O toBeEncodedFile.sh https://raw.githubusercontent.com/branchnetconsulting/wazuh-tools/master/merge-wazuh-conf.sh
        #    cat toBeEncodedFile.sh  | base64 -w0
}

# Uninstallion function
function uninstallsuite() {

if [ -f /var/ossec/etc/ossec.log ]; then
	cp /var/ossec/etc/ossec.log /tmp/
fi

# Shut down and clean out any previous Wazuh or OSSEC agent
systemctl stop wazuh-agent 2> /dev/null
systemctl stop ossec-hids-agent 2> /dev/null
systemctl stop ossec-agent 2> /dev/null
service wazuh-agent stop 2> /dev/null
service ossec-hids-agent stop 2> /dev/null
service stop ossec-agent stop 2> /dev/null
yum -y erase wazuh-agent 2> /dev/null
yum -y erase ossec-hids-agent 2> /dev/null
yum -y erase ossec-agent 2> /dev/null
apt-get -y purge wazuh-agent 2> /dev/null
apt-get -y purge ossec-hids-agent 2> /dev/null
apt-get -y purge ossec-agent 2> /dev/null
kill -kill `ps auxw | grep "/var/ossec/bin" | grep -v grep | awk '{print $2}'` 2> /dev/null
rm -rf /var/ossec /etc/ossec-init.conf 2> /dev/null
# Clean out any previous Osquery
dpkg --purge osquery 2> /dev/null
yum -y erase osquery 2> /dev/null
rm -f /usr/bin/osqueryd 2> /dev/null  # pre-5.x binary or symlink to it 
rm -f /usr/bin/osqueryi 2> /dev/null  # pre-5.x binary or symlink to it 
rm -rf /var/osquery /var/log/osquery /usr/share/osquery /opt/osquery
if [ $Uninstall == 1 ]; then
        echo -e "\n*** Wazuh Agent suite successfully uninstalled";
        exit 0
fi
}

# Checks function
function checksuite() {
if [ -f /etc/nsm/securityonion.conf ]; then
		if [ $Debug == 1 ]; then echo -e "\n*** This deploy script cannot be used on a system where Security Onion is installed."; fi
        exit 2
fi
if [[ `grep -s server /etc/ossec-init.conf` ]]; then
        if [ $Debug == 1 ]; then echo -e "\n*** This deploy script cannot be used on a system where Wazuh manager is already installed."; fi
        exit 2
fi
if [ "$WazuhMgr" == "" ]; then
        echo -e "\n*** Must use '-WazuhMgr' to specify the FQDN or IP of the Wazuh manager to which the agent shall retain a connection."
        show_usage
        exit 2
fi
if [ "$WazuhRegMgr" == "" ]; then
        WazuhRegMgr=$WazuhMgr
fi
if [ "$WazuhVer" == "" ]; then
        echo -e "\n*** Must use '-WazuhVer' to specify the Wazuh Agent version to check for."
        show_usage
        exit 2
fi
if [[ "$OsqueryVer" == "" && "$SkipOsquery" == "0" ]]; then
        echo -e "\nIf -SkipOsquery is not specified, then -OsqueryVer must be provided."
        show_usage
        exit 2
fi

# Determine how old the state file is ( 0 means absent )
mtime=`stat -c%Y /var/ossec/var/run/wazuh-agentd.state 2> /dev/null`
if [[ "$mtime" == "" ]]; then
        mtime=0
fi
sfage=$((`date +%s`-$mtime))

if [[ ! -f /var/ossec/var/run/wazuh-agentd.state || ! `grep "status='connected'" /var/ossec/var/run/wazuh-agentd.state 2> /dev/null` || $sfage -gt 70 ]]; then
	# Confirm the self registration and agent connection ports on the manager(s) are responsive.
	# If either are not, then (re)deployment is not feasible, so return an exit code of 2 so as to not trigger the attempt of such.
	tprobe $WazuhMgr 1514
	tprobe $WazuhRegMgr 1515
	# Load Balancer Specific check for actual connection to a Wazuh Manager
	if [[ "$LBprobe" == "1" && -e /var/ossec/bin/agent-auth ]]; then 
		if [ $Debug == 1 ]; then echo "Performing a load-balancer-aware check via an agent-auth.exe call to confirm manager is truly reachable..."; fi
		rm /tmp/lbprobe
		/var/ossec/bin/agent-auth -m $WazuhMgr -p1515 -P bad &> /tmp/lbprobe &
		sleep 5
		kill `ps auxw | grep agent-auth | grep -v grep | awk '{print $2}'` 2>/dev/null
		if [[ `grep "Invalid password" /tmp/lbprobe` ]]; then
			if [ $Debug == 1 ]; then echo "The Wazuh Manager auth daemon is reachable."; fi
		else
			if [ $Debug == 1 ]; then echo "Cannot reach Wazuh Manager auth daemon."; fi
			exit 2
		fi
	fi
fi

#
# Is the agent presently really connected to the Wazuh manager?
#
if [[ ! `grep "'connected'" /var/ossec/var/run/wazuh-agentd.state 2> /dev/null` || $sfage -gt 70 ]]; then
	if [ $sfage -lt 70 ]; then
		if [ $Debug == 1 ]; then echo "*** The Wazuh agent is not connected to the Wazuh manager, waiting 90 seconds."; fi
		sleep 90
	fi
	if [[ ! `grep "'connected'" /var/ossec/var/run/wazuh-agentd.state 2> /dev/null` ]]; then
                if [ $Debug == 1 ]; then echo "*** The Wazuh agent is still not connected to the Wazuh manager."; fi
                if [ $CheckOnly == 1 ]; then
                        exit 1
                else
                        deploysuite
                fi
        else
                if [ $Debug == 1 ]; then echo "The Wazuh agent is connected to the Wazuh manager."; fi
        fi
fi

#
# Connected to the right manager?
#
CURR_MGR=`grep address /var/ossec/etc/ossec.conf | sed 's/.*>\([^<]\+\).*/\1/'`
if  [[ "$CURR_MGR" != "$WazuhMgr" ]]; then
        if [ $Debug == 1 ]; then echo "The Wazuh agent is not connected to the right manager."; fi 
                if [ $CheckOnly == 1 ]; then
                        exit 1
                else
                        deploysuite
                fi
else
        if [ $Debug == 1 ]; then echo "The Wazuh agent is connected to the right manager."; fi
fi        

#
# Is the agent currently a member of all intended Wazuh agent groups, and no others?
#
# Split Linux into two basic categories: deb and rpm, and work up the full set of Wazuh agent groups including dynamically set prefix plus custom extras.
# This needs to be refined, but reflects the Linux flavors I actually work with.
# Do not perform agent group check if
if [ "$WazuhGroups" != "#NOGROUP#" ]; then
        WazuhGroupsPrefix="linux,linux-local,"
        if [[ -f /etc/os-release && `grep -i debian /etc/os-release` ]]; then
                LinuxFamily="deb"
        else
                LinuxFamily="rpm"
        fi
        if [ "$SkipOsquery" == "0" ]; then
                WazuhGroupsPrefix="${WazuhGroupsPrefix}osquery,osquery-local,"
        fi
        WazuhGroups="${WazuhGroupsPrefix}$WazuhGroups"
        # If there were no additional groups, strip off the trailing comma in the list.
        WazuhGroups=`echo $WazuhGroups | sed 's/,$//'`
        CURR_GROUPS=`echo \`grep "<\!-- Source file: " /var/ossec/etc/shared/merged.mg | cut -d" " -f4 | cut -d/ -f1 \` | sed 's/ /,/g'`
        if [ $Debug == 1 ]; then echo "Current agent groups: $CURR_GROUPS"; fi
        if [ $Debug == 1 ]; then echo "Target agent groups:  $WazuhGroups"; fi
        if [ "$CURR_GROUPS" != "$WazuhGroups" ]; then
                if [ $Debug == 1 ]; then echo "*** Current and target groups to not match."; fi
				if [ $CheckOnly == 1 ]; then
						exit 1
				else
						deploysuite
                        	fi
        else
                if [ $Debug == 1 ]; then echo "Current and target groups match."; fi
        fi
else
        if [ $Debug == 1 ]; then echo "Skipping the agent group check since no -WazuhGroups was provided."; fi
fi

#
# Is the target version of Wazuh agent installed?
#
if [ -f /var/ossec/bin/wazuh-control ] && [[ `/var/ossec/bin/wazuh-control info | grep "\"v$WazuhVer\""` ]] || [[ `grep "\"v$WazuhVer\"" /etc/ossec-init.conf` ]]; then
        if [ $Debug == 1 ]; then echo "The running Wazuh agent appears to be at the desired version ($WazuhVer)."; fi
else
        if [ $Debug == 1 ]; then echo "*** The running Wazuh agent does not appear to be at the desired version ($WazuhVer)."; fi
        if [ $CheckOnly == 1 ]; then
                exit 1
        else
                deploysuite
        fi
fi
#
# If not ignoring Osquery, is the target version of Osquery installed and running?
#
if [ "$SkipOsquery" == "0" ]; then
       if [[ ! `ps auxw | grep -v grep | egrep "osqueryd.*osquery-linux.conf"` ]]; then
                if [ $Debug == 1 ]; then echo "*** No osqueryd child process was found under the wazuh-modulesd process."; fi
		if [ $CheckOnly == 1 ]; then
				exit 1
		else
                       		deploysuite
                fi
        else
                if [ $Debug == 1 ]; then echo "Osqueryd was found running under the wazuh-modulesd process."; fi
        fi
        CURR_OSQ_VER=`/usr/bin/osqueryi --csv "select version from osquery_info;" | tail -n1`
        if [ ! "$CURR_OSQ_VER" == "$OsqueryVer" ]; then
                if [ $Debug == 1 ]; then echo "*** The version of Osquery running on this system ($CURR_OSQ_VER) is not the target version ($OsqueryVer)."; fi
                        if [ $CheckOnly == 1 ]; then
					exit 1
			else
                        		deploysuite
                        fi
        else
                if [ $Debug == 1 ]; then echo "The target version of Osquery is running on this system."; fi
        fi
else
        if [ $Debug == 1 ]; then echo "Ignoring Osquery..."; fi
fi

#
# Passed!
#
if [ $Debug == 1 ]; then echo "No deployment/redeployment appears to be needed."; fi
exit 0
}

# Deploy function
function deploysuite() {
if [ "$WazuhGroups" == "#NOGROUP#" ]; then
        GROUPS_SKIPPED=1
        WazuhGroups=""
else
        GROUPS_SKIPPED=0
fi

if [ -f /etc/nsm/securityonion.conf ]; then
        echo -e "\n*** This deploy script cannot be used on a system where Security Onion is installed."
        show_usage
        exit 2
fi
if [[ `grep server /etc/ossec-init.conf` ]]; then
        echo -e "\n*** This deploy script cannot be used on a system where Wazuh manager is already installed."
        show_usage
        exit 2
fi

if [ "$WazuhMgr" == "" ]; then
        echo -e "\n*** WazuhMgr variable must be used to specify the FQDN or IP of the Wazuh manager to which the agent shall retain a connection."
	show_usage
        exit 2
fi

if [ "$WazuhRegPass" == "" ]; then
        echo -e "\n*** WazuhRegPass variable must be used to specify the password to use for agent registration."
        show_usage
        exit 2
fi

if [[ "$WazuhVer" == "" && "$WazuhSrc" == "" ]]; then
        echo -e "\n*** Must use '-WazuhVer' or '-WazuhSrc' to specify which Wazuh agent to (re)install (and possibly download first)."
        show_usage
        exit 2
fi

if [[ "$WazuhVer" != "" && "$WazuhSrc" != "" ]]; then
        echo -e "\n*** Must use either '-WazuhVer' or '-WazuhSrc' (not both) to specify which Wazuh agent to (re)install (and possibly download first)."
        show_usage
        exit 2
fi

if [[ "$WazuhRegMgr" == "" ]]; then
        WazuhRegMgr="$WazuhMgr"
fi

# Split Linux into two basic categories: deb and rpm, and work up the full set of Wazuh agent groups including dynamically set prefix plus custom extras.
# This needs to be refined, but reflects the Linux flavors I actually work with.
WazuhGroupsPrefix="linux,linux-local,"
if [[ -f /etc/os-release && `grep -i debian /etc/os-release` ]]; then
        LinuxFamily="deb"
else
        LinuxFamily="rpm"
fi
if [ "$SkipOsquery" == "0" ]; then
        WazuhGroupsPrefix="${WazuhGroupsPrefix}osquery,osquery-local,"
fi
WazuhGroups="${WazuhGroupsPrefix}$WazuhGroups"
# If there were no additional groups, strip off the trailing comma in the list.
WazuhGroups=`echo $WazuhGroups | sed 's/,$//'`

if [ "$WazuhSrc" == "" ]; then
        WazuhMajorVer=`echo $WazuhVer | cut -c1`
        if [ "$LinuxFamily" == "deb" ]; then
                WazuhSrc="https://packages.wazuh.com/$WazuhMajorVer.x/apt/pool/main/w/wazuh-agent/wazuh-agent_$WazuhVer-1_amd64.deb"
	else
		WazuhSrc="https://packages.wazuh.com/$WazuhMajorVer.x/yum/wazuh-agent-$WazuhVer-1.x86_64.rpm"
        fi
fi

if [[ "$OsqueryVer" == "" && "$SkipOsquery" == 0 && "$OsquerySrc" == "" ]]; then
        echo -e "\n*** Must use '-OsqueryVer' or '-OsquerySrc' or '-SkipOsquery' to indicate if/how to handle Osquery (re)installation/removal."
        show_usage
        exit 2
fi

if [[ "$OsqueryVer" != "" && "$OsquerySrc" != "" ]]; then
        echo -e "\n*** Cannot specify both '-OsqueryVer' and '-OsquerySrc'."
        show_usage
        exit 2
fi


if [ "$OsquerySrc" == "" ]; then
        if [ "$LinuxFamily" == "deb" ]; then
                OsquerySrc="https://pkg.osquery.io/deb/osquery_${OsqueryVer}_1.linux.amd64.deb"
		OsquerySrc2="https://pkg.osquery.io/deb/osquery_${OsqueryVer}-1.linux_amd64.deb"
        else
                OsquerySrc="https://pkg.osquery.io/rpm/osquery-${OsqueryVer}-1.linux.x86_64.rpm"
        fi
fi

# If no custom agent name specified, use the internal Linux hostname.
if [ "$WazuhAgentName" == "" ]; then
        WazuhAgentName=`hostname`
fi

cd ~

# Take note if agent is already connected to a Wazuh manager and collect relevant data
ALREADY_CONNECTED=0
if [[ `cat /var/ossec/var/run/wazuh-agentd.state 2> /dev/null | grep "'connected'"` ]]; then
        ALREADY_CONNECTED=1
        OLDNAME=`cut -d" " -f2 /var/ossec/etc/client.keys 2> /dev/null`
        CURR_GROUPS=`echo \`grep "<\!-- Source file: " /var/ossec/etc/shared/merged.mg | cut -d" " -f4 | cut -d/ -f1 \` | sed 's/ /,/g'`
	CURR_MGR=`grep address /var/ossec/etc/ossec.conf | sed 's/.*>\([^<]\+\).*/\1/'`
        rm -f /tmp/client.keys 2> /dev/null
        cp -p /var/ossec/etc/client.keys /tmp/
fi

if [ $Debug == 1 ]; then
        echo -e "\nWazuhMgr: $WazuhMgr"
        echo "WazuhRegMgr: $WazuhRegMgr"
        echo "WazuhRegPass: $WazuhRegPass"
        echo "WazuhVer: $WazuhVer"
        echo "WazuhAgentName: $WazuhAgentName"
        echo "WazuhSrc: $WazuhSrc"
        echo "OsqueryVer: $OsqueryVer"
        echo "OsquerySrc: $OsquerySrc"
        echo "SkipOsquery: $SkipOsquery"
        echo "ALREADY_CONNECTED: $ALREADY_CONNECTED"
        echo "OLDNAME: $OLDNAME"
        echo "WazuhGroups: $WazuhGroups"
        echo "CURR_GROUPS: $CURR_GROUPS"
        echo -e "GROUPS_SKIPPED: $GROUPS_SKIPPED\n"
fi

uninstallsuite

#
# Branch between Ubuntu and CentOS for Wazuh agent installation steps
# Dynamically generate a Wazuh config profile name for the linux flavor, version, and if applicable subversion, like ubuntu, ubuntu20, ubuntu 20.04 or centos, centos8
#
if [ "$LinuxFamily" == "deb" ]; then
        # Wazuh Agent remove/download/install
	if [[ ! `which wget 2> /dev/null` ]]; then 
		apt -y install wget
	fi
        rm -f /tmp/wazuh-agent_$WazuhVer-1_amd64.deb 2> /dev/null
        wget -O /tmp/wazuh-agent_$WazuhVer-1_amd64.deb $WazuhSrc
        dpkg -i /tmp/wazuh-agent_$WazuhVer-1_amd64.deb
        rm -f /tmp/wazuh-agent_$WazuhVer-1_amd64.deb
        CFG_PROFILE=`. /etc/os-release; echo $ID, $ID\`echo $VERSION_ID | cut -d. -f1\`, $ID\`echo $VERSION_ID\``
else
        # Wazuh Agent remove/download/install
	if [[ ! `which wget 2> /dev/null` ]]; then 
		yum -y install wget
	fi
	rm -f /tmp/wazuh-agent-$WazuhVer-1.x86_64.rpm 2> /dev/null
        wget -O /tmp/wazuh-agent-$WazuhVer-1.x86_64.rpm $WazuhSrc
        yum -y install /tmp/wazuh-agent-$WazuhVer-1.x86_64.rpm
        rm -f /tmp/wazuh-agent-$WazuhVer-1.x86_64.rpm
	CFG_PROFILE=`. /etc/os-release; echo $ID, $ID\`echo $VERSION_ID\``
	if [[ -f /etc/redhat-release && `grep "CentOS release 6" /etc/redhat-release` ]]; then
		CFG_PROFILE="centos, centos6, centos6.`cut -d. -f2 /etc/redhat-release | cut -d\" \" -f1`"
	fi
fi

# Create /var/ossec/custbin and write merge-wazuh-conf.sh file to it.
# writeMergeScript

if [[ `which systemctl 2> /dev/null` ]]; then
	systemctl enable wazuh-agent
else
	chkconfig wazuh-agent on
fi

#
# If we can safely skip self registration and just restore the backed up client.keys file, then do so. Otherwise, self-register.
# This should keep us from burning through so many agent ID numbers.
# Furthermore, when re-registering, if -WazuhGroups was not specified and an existing set of group memberships is detected and the agent is presently connected,
# then preserve those groups during the re-registration instead of rebuilding a standard group list.
#
if [ "$ALREADY_CONNECTED" == "1" ]; then
        if [[ "$WazuhAgentName" == "$OLDNAME" && "$CURR_MGR" == "$WazuhMgr" && ( "$CURR_GROUPS" == "$WazuhGroups" || "$GROUPS_SKIPPED" == "1" ) ]]; then
                echo "Old and new agent registration names, groups and manager match."
                cp -p /tmp/client.keys /var/ossec/etc/
        else
                echo "Registration information has changed."
                if [[  "$GROUPS_SKIPPED" == "1" && "$CURR_GROUPS" != "" ]]; then
                        /var/ossec/bin/agent-auth -m "$WazuhRegMgr" -P "$WazuhRegPass" -G "$CURR_GROUPS" -A "$WazuhAgentName"
                else
                        /var/ossec/bin/agent-auth -m "$WazuhRegMgr" -P "$WazuhRegPass" -G "$WazuhGroups" -A "$WazuhAgentName"
                fi
        fi
else
        if [[  "$GROUPS_SKIPPED" == "1" && "$CURR_GROUPS" != "" ]]; then
                /var/ossec/bin/agent-auth -m "$WazuhRegMgr" -P "$WazuhRegPass" -G "$CURR_GROUPS" -A "$WazuhAgentName"
        else
                /var/ossec/bin/agent-auth -m "$WazuhRegMgr" -P "$WazuhRegPass" -G "$WazuhGroups" -A "$WazuhAgentName"
        fi
fi

#
# If not set to be skipped, download and install osquery.
#
if [ "$SkipOsquery" == "0" ]; then
	if [ "$LinuxFamily" == "deb" ]; then
	        rm -f osquery.deb 2> /dev/null
                wget -O osquery.deb $OsquerySrc
		if [[ ! `file osquery.deb | grep "binary package"` ]]; then
			wget -O osquery.deb $OsquerySrc2 
		fi
		dpkg -i osquery.deb
                rm -f osquery.deb
	else
		rm -f osquery.rpm 2> /dev/null
		wget -O osquery.rpm $OsquerySrc
		yum -y install osquery.rpm
		rm -f osquery.rpm
	fi

	if [[ `which systemctl 2> /dev/null` ]]; then
		systemctl stop osqueryd
		systemctl disable osqueryd
	else
		service osqueryd stop
		chkconfig osqueryd off
	fi

	# Add symlinks from pre 5.x osqueryd and osqueryi executables to 5.x locations for compatibility
	ln -s /opt/osquery/bin/osqueryd /usr/bin/osqueryd 2> /dev/null
	ln -s /usr/local/bin/osqueryi /usr/bin/osqueryi 2> /dev/null
fi

#
# Dynamically generate ossec.conf
#
echo "
<ossec_config>
  <client>
    <server>
      <address>$WazuhMgr</address>
      <port>1514</port>
      <protocol>tcp</protocol>
    </server>
    <config-profile>$CFG_PROFILE</config-profile>
    <notify_time>10</notify_time>
    <time-reconnect>60</time-reconnect>
    <auto_restart>yes</auto_restart>
    <crypto_method>aes</crypto_method>
    <enrollment>
        <enabled>no</enabled>
    </enrollment>
  </client>
  <logging>
    <log_format>plain, json</log_format>
  </logging>
</ossec_config>
" > /var/ossec/etc/ossec.conf

#
# Dynamically generate local_internal_options.conf
#
echo "
# Logcollector - If it should accept remote commands from the manager
logcollector.remote_commands=1

# Wazuh Command Module - If it should accept remote commands from the manager
wazuh_command.remote_commands=1

# Enable it to accept execute commands from SCA policies pushed from the manager in the shared configuration
# Local policies ignore this option
sca.remote_commands=1
" > /var/ossec/etc/local_internal_options.conf

# Restart the Wazuh agent (and Osquery subagent)
if [[ `which systemctl 2> /dev/null` ]]; then
        systemctl stop wazuh-agent
	systemctl daemon-reload
	systemctl enable wazuh-agent
	systemctl start wazuh-agent
else
        service wazuh-agent restart
fi

# /var/ossec/custbin/merge-wazuh-conf.sh

echo "Waiting 15 seconds before checking connection status to manager..."
sleep 15
if [[ `cat /var/ossec/logs/ossec.log | grep "Connected to the server "` ]]; then
        echo "Agent has successfully reported into the manager."
        exit 0
else
        echo "Something appears to have gone wrong.  Agent is not connected to the manager."
        exit 2
fi
}

if [ $Install == 1 ]; then
        deploysuite
elif [ $Uninstall == 1 ]; then
        uninstallsuite
else
        checksuite
fi
