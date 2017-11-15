#!/bin/bash

## Parse json function
json_key() {
    python -c '
import json
import sys

data = json.load(sys.stdin)

for key in sys.argv[1:]:
    try:
        data = data[key]
    except TypeError:  # This is a list index
        data = data[int(key)]
    except NameError:
        print(key +" is not yet defined")
        exit(1)
print(data)' "$@"
}

parse_result() {
  python -c '
import json;
import sys 
data = json.load(sys.stdin); 
for alternative in data["response"]["results"]:
    print(alternative["alternatives"][0]["transcript"])
' "$@"
}
 
## Help
usage() {
      echo -e "\n"
      echo "Usage:"
      echo "    ./voicelog.sh -h"
      echo "    ./voicelog.sh -l en-US -f MP3 -u http://joker.com/says/why_so_serious.mp3"
      echo "    ./voicelog.sh -l en-US -f MP3 -b sgandh31audio -u http://example.com/some.mp3"
      echo ""
      echo "    -h, --help         : Displays this help message"
      echo "    -l, --languagecode : BCP-47 language codes like en-US en-UK." 
      echo "                         More info: https://cloud.google.com/speech/docs/languages"
      echo "    -f, --format       : Supported formats: MP3 FlAC"
      echo "    -b, --bucket       : Google Storage bucket name. Default: sgandh31audio"
      echo ""
      exit 0
}
url=""
format=""
lang=""

f_flag=false
l_flag=false
u_flag=false
b_flag=false
while getopts ":f:l:b:u:h" opt; do
  case ${opt} in
    h ) usage; exit 0
      ;;
    f ) format=${OPTARG}; f_flag=true;
      ;;
    l ) lang=${OPTARG}; l_flag=true;
      ;;
    b ) bucket=${OPTARG}; b_flag=true;
      ;;
    u ) url=${OPTARG}; u_flag=true;
      ;;
    : )
      echo "Option -$OPTARG requires an argument." 1>&2
      exit 1
      ;;
    \? )
      echo "Invalid Option: -$OPTARG" 1>&2
      exit 1
      ;;
  esac
done
shift $((OPTIND -1))

if ! ${f_flag} ||  [[ "x${format}" != "xMP3" && "x${format}" != "xFLAC" ]] ; then 
   echo -e "\naudio encoding format (MP3 or FLAC) is mandatory." 1>&2
   exit 1
fi 
if ! ${u_flag} ; then 
   echo -e "\naudio url is mandatory." 1>&2
   exit 1
fi 
if ! ${l_flag} ; then 
   echo -e "\naudio language code (like en-US) is mandatory."  1>&2
   exit 1
fi

if ! ${b_flag} ; then 
   echo -e "\nBucket gs://sgandh31audio/ will be used."
   bucket=sgandh31audio
else
   echo -e "\n Bucket gs://${bucket}/ will be used. Make sure that proper IAM rules have been assigned"  1>&2
fi


echo "l_flag=${l_flag} lang=${lang}"
echo "u_flag=${u_flag} url=${url}"
echo "f_flag=${f_flag} format=${format}"
echo "b_flag=${b_flag} bucket=${bucket}"

format_lowercase=`echo ${format} | tr [A-Z] [a-z]`
audio_file=`echo ${RANDOM}.${format_lowercase}`

echo -e "\n\nDownloading the audio file from the given url"
if [[ ${url} == http* ]]; then
    wget --no-check-certificate -O ${audio_file} ${url}
elif [[ ${url} == gs* ]] ; then
    gsutil cp ${url} ${audio_file}
else
    echo -e "\n\nError: Unsupported or invalid url" 1>&2
    exit 1
fi

ls -lrt ${audio_file}
audio_filename="${audio_file%.*}"
audio_extension="${audio_file##*.}"
flac_audio_file=flac-${audio_filename}.flac
flac_audio_filename="${flac_audio_file%.*}"

echo -e "\n *******  Installing sox and libsox-fmt-mp3 if not already installed"
sudo apt-get -q -y install sox libsox-fmt-mp3

echo -e "\n *******  Converting the audio file into single channel flac format"
sox -t ${format_lowercase} ${audio_file} -t flac ${flac_audio_file} channels 1 rate 16k

keyfile=key.json
if test -r "$keyfile" -a -f "$keyfile"; then
    echo -e "\nUsing ./key.json as your Google Cloud credentials"
else
    echo -e "\n\nError: key.json file containing your Google Cloud credentials either does not exist or is not readable" 1>&2
    exit 1
fi
export GOOGLE_APPLICATION_CREDENTIALS=key.json
echo -e "\n *******  Uploading the formatted audio file : ${flac_audio_file} to gcloud storage gs://${bucket}/${flac_audio_file}"
gsutil cp ${flac_audio_file} gs://${bucket}/${flac_audio_file}
if [ $? -eq 0 ]; then
    echo "\n ******* Successfully uploaded the file : ${flac_audio_file}"
else
    echo -e "\n\nError: Could not upload file to the bucket gs://${bucket} for user in ./key.json. Please check bucket name and IAM permissions" 1>&2
    exit 1
fi
gsutil ls gs://${bucket}/${flac_audio_file}

token=`gcloud auth application-default print-access-token`
cp template.json d.json
sed -i s/\"lang\"/\"${lang}\"/g d.json
sed -i s/bucketname/${bucket}/g d.json
sed -i s/flac_audio_file/${flac_audio_file}/g d.json


curl --output request_id -s -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${token}" \
    https://speech.googleapis.com/v1/speech:longrunningrecognize \
    -d @d.json

cat request_id
name=`json_key name < request_id`
key=AIzaSyDrkzrOxnmyxeK6x8vOTyKWKsP3t1TE-ks
url="https://speech.googleapis.com/v1/operations/${name}?key=${key}"
command="curl -s --output speech_api_response.json -X GET ${url}"
echo "Sleeping for 30 seconds"
sleep 30
echo "${command}"
eval "${command}"

echo "Sit back and relax. Have a cup of tea or coffee"
echo "Depending on the size and duration of the audio, this may take a few minutes"

result=`json_key done < speech_api_response.json`
result=`echo ${result} | tr [A-Z] [a-z]`
while [ ! ${result} ]
do
    echo "Sleeping for 30 seconds"
    sleep 30
    eval ${command}
    result=`json_key done < speech_api_response.json`
    result=`echo ${result} | tr [A-Z] [a-z]`
done

echo -e "\n\n\n**********   Your voicelog: ${name} is ready   *************\n"
parse_result < speech_api_response.json
echo -e "\n***********************"
rm -rf ${flac_audio_file}
rm -rf ${audio_file}

################################# push to elasticsearch ###############

