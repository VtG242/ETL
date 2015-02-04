#!/bin/bash
# task states - RUNNING,PREPARED,ERROR,OK

# connection information - edit to fit your needs
source auth.sh

# Globalni promene
ETLTASKSTATUS="ERROR"
ETLDATESTART=`date +"%Y-%m-%d %H:%M:%S"`
#defaultne vyplnime necim - v pripade ze nedostanu etl task id potrebuju mit unikatni hodnotu pro primarni klic pro zapis teto udalosti do GD
ETL_TASK_ID=`openssl rand -base64 6`
START=$(date +%s)
PID=$$

function gettt() {

    curl --silent \
    --write-out "GET /gdc/account/token --> %{http_code}\n"\
    --output step2.$PID \
    --include --header "Cookie: $SST_COOKIE" --header "Accept: application/json" --header "Content-Type: application/json" \
    --request GET "$SERVER/gdc/account/token"

}

#platform availeability check at first
curl --silent\
    --write-out "GET /gdc/ping --> %{http_code}\n"\
    --output platformcheck.$PID \
    --include --header "Accept: application/json" --header "Content-Type: application/json" \
    --request GET "$SERVER/gdc/ping"

#check curl state after platform checck
if [ "$?" == "0" ];then 


if [ `cat platformcheck.$PID | grep HTTP | awk {'print $2'}` == "204" ]; then
    MAINTANENCE="N"

    curl --silent\
         --write-out "POST /gdc/account/login --> %{http_code}\n"\
         --output step1.$PID \
         --include --header "Accept: application/json" --header "Content-Type: application/json" \
         --request POST "$SERVER/gdc/account/login"\
         --data-binary "{\"postUserLogin\":{\"login\":\"$USER\",\"password\":\"$PASS\",\"remember\":1}}"

    #check curl state after step1 - login
    if [ "$?" == "0" ];then 
 
        #curl skoncil normalne - zjistime cookie s SST
	if [ `cat step1.$PID | grep HTTP/1.1 | awk {'print $2'}` == "200" ];then
    
            USER_LOGIN_URL=`cat step1.$PID | grep "{\|}" | ./jq -r .userLogin.state`
	    SST_COOKIE=`cat step1.$PID | grep -v GDCAuthTT | grep --only-matching --perl-regex "(?<=Set-Cookie\: ).*"`
	    echo $SST_COOKIE;
	    echo $USER_LOGIN_URL;echo -e "\n";

	    #pokracujene zadosti o TT - step2 -  je treba udelat jako funkci protoze bude volana vicekrat - vzdy v pripade kdyz dostanu 401 zavolam si pro novy TT
	    gettt

	    #check curl state after step2
	    if [ "$?" == "0" ];then
	     
		TT_COOKIE=`cat step2.$PID | grep --only-matching --perl-regex "(?<=Set-Cookie\: ).*"`
		echo $TT_COOKIE
		echo -e "\n"

		#curl skoncil normalne - zjistime cookie s SST
		if [ `cat step2.$PID | grep HTTP/1.1 | awk {'print $2'}` == "200" ];then

		    #ETL start
		
		    #Autorizace hotove zde provedeme vlastni akci s API (ETL) - v pripade 401 opakujeme step2
		    curl --silent\
		    --write-out "POST /gdc/md/$PROJECT/etl/pull --> %{http_code}\n"\
		    --output step3.$PID \
		    --include --header "Accept: application/json" --header "Content-Type: application/json" \
		    --cookie "$TT_COOKIE" \
		    --request POST \
		    --data-binary "{\"pullIntegration\":\"$WEBDAVDIR\"}" \
		    "$SERVER/gdc/md/$PROJECT/etl/pull"

		    #check curl state after step3 - vlastni API call
		    if [ "$?" == "0" ];then

			#cat step3.txt
			if [ `cat step3.$PID | grep HTTP/1.1 | awk {'print $2'}` == "200" ]; then

			    #pool na etl task - dokud taskStatus == OK - vyzobneme jen uri ETL tasku 
			    ETL_TASK_URI=`cat step3.$PID | grep --only-matching --perl-regex "(?<=\"uri\"\:\").*[^\"\}]"`
			    #pro splunk vyzobneme jen cislo ETL tasku
			    ETL_TASK_ID=`echo $ETL_TASK_URI | cut -d/ -f7`
			    echo "ETL task ID: $ETL_TASK_ID";echo ""
			    #counter pro opakovani datazu na stav tasku v pripade problemu
			    ETLQUERYFAIL=1
			
			    #TIME - Start ETL
			    while :
			    do
				curl --silent\
				--write-out "GET $ETL_TASK_URI --> %{http_code}\n"\
				--output task.$PID \
				--cookie "$TT_COOKIE"\
				--include --header "Accept: application/json" --header "Content-Type: application/json" \
				--request GET "$SERVER$ETL_TASK_URI"
			    
				#provedeme kontrolu na navratovy status - pri 200 provedeme poll, pri 401 zazadame o novy TT
				case `cat task.$PID | grep HTTP/1.1 | awk {'print $2'}` in
				200)#vypreparujeme z task.txt odpovedi jen json
				    ETLQUERYFAIL=1
			    	    ETLTASKSTATUS=`cat task.$PID | grep "{\|}" | ./jq -r .taskStatus`
				    if [ $ETLTASKSTATUS == "OK" ]; then
					cat task.$PID;echo -e "\n";
					break
				    elif [ $ETLTASKSTATUS == "ERROR" ]; then
					echo "*** ETL task failed: ***"
					cat task.$PID;echo -e "\n";
					echo "Details from upload_status.json file from WebDav:"
					#TODO
					curl --user "vladimir.volcko%40gooddata.com:yyy" -G https://secure-di.gooddata.com/uploads/ETLTEST/upload_status.json
					break
				    else
					cat task.$PID | grep "{\|}";echo -e "\n";
					sleep 3;
				    fi
				    ;;
				401)cat task.$PID;echo -e "\n";
				    echo "Re-sending TT: "
				    #TODO - zde muzeme dostat chybu ze se curl call nepovede - zatim neresim predpokladam ze prvni check staci 
				    gettt
				    TT_COOKIE=`cat step2.$PID | grep --only-matching --perl-regex "(?<=Set-Cookie\: ).*"`
				    echo $TT_COOKIE
				    ;;
				*)  if [ $ETLQUERYFAIL == "10" ]; then
				        echo "Ten failed attempts to get a state of ETL ... I give it up:"
					cat task.$PID;echo -e "\n";
					break;
				    fi
				    echo "Problem with getting a state of ETL task ... retry in 30 second."
				    echo "FAIL: $ETLQUERYFAIL"
				    sleep 30;
				    let "ETLQUERYFAIL+=1";
			    	    ;;
				esac
			    
			    done
			    #TIME - End of ETL here
			
			else
			    #pro jiny navratovy kod nez 200 pri step3 zobrazime vystup z curlu
			    cat step3.$PID
			    echo -e "\n";
			fi
		    else
			echo "Step3 - etl/pull - Curl ended with unexpected code $? - check curl "
		    fi

		else
		    #pro jiny navratovy kod nez 200 pri step2 (TT call) zobrazime vystup z curlu
		    cat step2.$PID
		fi
     
	    else
		#problem s parsovanim vystupu z curlu ve step 1
		echo "Step2 - retrive TT token - Curl ended with unexpected code $? - check curl "
	    fi

	else
	    #pro jiny navratovy kod nez 200 po step1 zobrazime vystup z curlu - autorizace se pravdepodobne nezdarila
	    cat step1.$PID
	fi

    else
    
	#problem s curlem ?
	echo "Step1 - login attempt - curl ended with unexpected code $? - check curl "

    fi

else

  PINGRESPONSE=`tail -n1 platformcheck.$PID`
  if [ "$PINGRESPONSE" == "Scheduled maintenance in progress. Please try again later." ]; then
    MAINTANENCE="Y"
  else
    MAINTANENCE="N"
  fi
  
#konec platform checku
echo "$PINGRESPONSE"

fi

else

    #problem s curlem ?
    echo "Step0 - platform check- curl ended with unexpected code $? - check curl."

fi


#ETL END flag
END=$(date +%s)

#LOGOUT
curl --silent\
     --write-out "Logout: DELETE $USER_LOGIN_URL --> %{http_code}\n" \
     --output logout.$PID \
     --include --header "Accept: application/json" --header "Content-Type: application/json"\
     --header "Cookie: $SST_COOKIE" --header "Cookie: $TT_COOKIE"\
     --request DELETE "$SERVER$USER_LOGIN_URL"

rm -rf *.$PID

#ETL Summary:
RUNTIME=`echo "$END - $START" | bc`
echo ""
echo "========================================================="
echo "ETL finished with status $ETLTASKSTATUS in: $RUNTIME s."
echo "========================================================="
echo ""
echo "Processing data about ETL:"
echo "pidtask,dwh,start,status,maintainence,runtime" > etlstats-$PID.csv
echo "$PROJECT[$ETL_TASK_ID],$DWH,$ETLDATESTART,$ETLTASKSTATUS,$MAINTANENCE,$RUNTIME" >> etlstats-$PID.csv
echo "ETL stats have been written in etlstats-$PID.csv"
touch csv/etlstats-archive.csv
tail -n1 etlstats-$PID.csv >> csv/etlstats-archive.csv

if [ $ETLTASKSTATUS == "OK" ]; then

   echo -n "POST ETL phase - Getting data from Splunk about the ETL: "
  /usr/bin/curl -s \
              -u $AUTHSTRING \
              -k https://$SPLUNKHOST:8089/services/search/jobs/export \
              -d search="search $PROJECT%20task_type%3D%22perl.slinode%22%20action%3D%22sli2dli%22%20etl_upload%3D%22%5B$ETL_TASK_ID%5D%22%20status%3D%22FINISHED%22%20earliest%3D-1h%20%7C%20eval%20host%3Dsplit(host%2C%20%22.%22)%20%7C%20eval%20host%3Dmvindex(host%2C0)%20%7C%20eval%20etl_upload%3Dproject.etl_upload%20%7C%20eval%20time%3Dround(time%2C0)%20%7C%20table%20etl_upload%20host%20time" \
              -d output_mode=csv -o etldetails-spl-$PID.csv

  #if success - wait and fetch results
  if [ "$?" == "0" ]; then
    echo "... [OK]"

    echo "etlid,csvnode,sli2dlitime,totaltime" > etldetails-$PID.csv
    tail -n1  etldetails-spl-$PID.csv | tr '\n' ',' >> etldetails-$PID.csv; echo $RUNTIME >> etldetails-$PID.csv
    echo "ETL details have been written in etldetails-$PID.csv"

    touch csv/etldetails-archive.csv
    tail -n1 etldetails-$PID.csv >> csv/etldetails-archive.csv

  else
     echo "Error during getting data from Splunk."
  fi

fi
