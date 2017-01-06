##############################################
# $Id: 14_FHEMduino_Env.pm 3818 2014-06-13 $
package main;

use strict;
use warnings;
use POSIX;


my %winddirection2compass = (
	"0" => "N",
	"45" => "NE",
	"90" => "E",
	"135" => "SE",
	"180" => "S",
	"225" => "SW",
	"270" => "W",
	"315" => "NW",
);

my %bft2text = (
  0 => "Windstille",
  1 => "leiser Zug",
  2 => "leichte Brise",
  3 => "schwache Brise",
  4 => "m&auml;&szlig;ige Brise",
  5 => "frische Brise",
  6 => "starker Wind",
  7 => "steifer Wind",
  8 => "st&uuml;rmischer Wind",
  9 => "Sturm",
  10 => "schwerer Sturm",
  11 => "orkanartiger Sturm",
  12 => "Orkan",
  
);

sub crosssum($$);
#####################################
sub
FHEMduino_Env_Initialize($)
{
  my ($hash) = @_;

  # output format is "WMMRRRRRRRRR"
  #                   W0358DA11C39
  #     W = W(eather sensor)
  #     M = M(anufactor code)
  #         01 = KW9010
  #         02 = EuroChron / Tchibo
  #         03 = PEARL NC7159, LogiLink WS0002
  #         04 = Lifetec
  #         05 = TX70DTH (Aldi)
  #         06 = AURIOL (Lidl Version: 09/2013)
  #     R = Raw data in hex (9 Byte)
  
  $hash->{Match}     = "W.*\$";
  $hash->{DefFn}     = "FHEMduino_Env_Define";
  $hash->{UndefFn}   = "FHEMduino_Env_Undef";
  $hash->{AttrFn}    = "FHEMduino_Env_Attr";
  $hash->{ParseFn}   = "FHEMduino_Env_Parse";
  $hash->{AttrList}  = "IODev do_not_notify:0,1 showtime:0,1 ignore:0,1 ".$readingFnAttributes;
  $hash->{AutoCreate}=
        { "FHEMduino_Env.*" => { GPLOT => "temp4hum4:Temp/Hum,", FILTER => "%NAME" } };
}


#####################################
sub
FHEMduino_Env_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  return "wrong syntax: define <name> FHEMduino_Env <code> <minsecs> <equalmsg>".int(@a)
		if(int(@a) < 3 || int(@a) > 5);

  $hash->{CODE}    = $a[2];
  $hash->{minsecs} = ((int(@a) > 3) ? $a[3] : 0);
  $hash->{equalMSG} = ((int(@a) > 4) ? $a[4] : 0);
  $hash->{lastMSG} =  "";
  $hash->{bitMSG} =  "";

  $modules{FHEMduino_Env}{defptr}{$a[2]} = $hash;
  $hash->{STATE} = "Defined";

  AssignIoPort($hash);
  return undef;
}

#####################################
sub
FHEMduino_Env_Undef($$)
{
  my ($hash, $name) = @_;
  delete($modules{FHEMduino_Env}{defptr}{$hash->{CODE}}) if($hash && $hash->{CODE});
  return undef;
}

#####################################
sub
FHEMduino_Env_Parse($$)
{
  my ($hash,$msg) = @_;
  my @a = split("", $msg);
  
  if (length($msg) < 12) {
    Log3 "FHEMduino", 4, "FHEMduino_Env: wrong message -> $msg";
    return "";
  }

  my $bitsequence = "";
  my $model = sprintf("%02d", substr($msg,1,2)); # getting manufactor model

  my $hextext = substr($msg,3);
  my $hexlen = length($hextext);
  if ($hexlen > 8) {
    $bitsequence = hex2bin(substr($hextext,0,8)); # getting message string and converting in bit sequence
    $bitsequence = $bitsequence.hex2bin(substr($hextext,8)); # substr(565A13F12,0,8)
  } else {
    $bitsequence = hex2bin($hextext); # getting message string and converting in bit sequence
  }

  Log3 $hash, 4, "FHEMduino_Env: $msg";
  Log3 $hash, 4, "FHEMduino_Env: $hextext";
  Log3 $hash, 4, "FHEMduino_Env: $bitsequence";
  
  #         01 = KW9010
  #         02 = EuroChron / Tchibo
  #         03 = PEARL NC7159, LogiLink WS0002
  #         04 = Lifetec
  #         05 = TX70DTH (Aldi)
  #         06 = AUREOL (Lidl Version: 09/2013)
  
  my $bin = "";
  my $deviceCode;
  my $SensorTyp;
  my $val = "";
  my ($channel, $tmp, $temp, $hum, $bat, $sendMode, $trend);
	my ($windspeed, $winddirection, $windgust, $rain, $bft);
	
	$winddirection = '?';
	$windgust = '?';
	$windspeed = '?';
	$rain = '?';

  if ($model eq "01") {			# KW9010
  # Re: Tchibo Wetterstation 433 MHz - Dekodierung mal ganz einfach 
  # See also http://forum.arduino.cc/index.php?PHPSESSID=ffoeoe9qeuv7rf4fh0d637hd74&topic=136836.msg1536416#msg1536416
  #                 /------------------------------------- Random ID part one      
  #                /    / -------------------------------- Channel switch       
  #               /    /  /------------------------------- Random ID part two      
  #              /    /  /  / ---------------------------- Battery state 0 == Ok      
  #             /    /  /  / / --------------------------- Trend (continous, rising, falling      
  #            /    /  /  / /  / ------------------------- forced send      
  #           /    /  /  / /  /  / ----------------------- Temperature
  #          /    /  /  / /  /  /          /-------------- Temperature sign bit. if 1 then temp = temp - 4096
  #         /    /  /  / /  /  /          /  /------------ Humidity
  #        /    /  /  / /  /  /          /  /       /----- Checksum
  #       0110 00 10 1 00 1  000000100011  00001101 1101
  #       0110 01 00 0 10 1  100110001001  00001011 0101
  # Bit   0    4  6  8 9  11 12            24       32
    $SensorTyp = "KW9010";
    $channel = bin2dec(substr($bitsequence,4,2));
    $bin = substr($bitsequence,0,4).substr($bitsequence,6,2);
    $deviceCode = sprintf('%X', oct("0b$bin"));
    $bat = int(substr($bitsequence,8,1)) eq "0" ? "ok" : "critical";
    $tmp = bin2dec(substr($bitsequence,9,2));
    if (int($tmp) == 1)
    {
      $trend = "rising";
    }
    elsif (int($tmp) == 2)
    {
      $trend = "falling";
    }
    else
    {
      $trend = "stable";
    }
    $sendMode = int(substr($bitsequence,11,1)) eq "0" ? "automatic" : "manual";
    $temp = bin2dec(binflip(substr($bitsequence,12,12)));
    if (substr($bitsequence,23,1) eq "1") {
      $temp = $temp - 4096;
    }
    $temp = $temp / 10.0;
    $hum = bin2dec(binflip(substr($bitsequence,24,8))) - 156;
    $val = "T: $temp H: $hum B: $bat";
  }
  elsif ($model eq "02") {      # EuroChron / Tchibo
  #                /--------------------------- Channel, changes after every battery change      
  #               /        / ------------------ Battery state 0 == Ok      
  #              /        / /------------------ unknown      
  #             /        / /  / --------------- forced send      
  #            /        / /  /  / ------------- unknown      
  #           /        / /  /  /     / -------- Humidity      
  #          /        / /  /  /     /       / - neg Temp: if 1 then temp = temp - 2048
  #         /        / /  /  /     /       /  / Temp
  #         01100010 1 00 1  00000 0100011 0  00011011101
  # Bit     0        8 9  11 12    17      24 25        36
    $SensorTyp = "EuroChron";
    $channel = "";
    $bin = substr($bitsequence,0,8);
    $deviceCode = sprintf('%X', oct("0b$bin"));
    $bat = int(substr($bitsequence,8,1)) eq "0" ? "ok" : "critical";
    $trend = "";
    $sendMode = int(substr($bitsequence,11,1)) eq "0" ? "automatic" : "manual";
    $temp = bin2dec(substr($bitsequence,25,11));
    if (substr($bitsequence,24,1) eq "1") {
      $temp = $temp - 2048;
    }
    $temp = $temp / 10.0;
    $hum = bin2dec(substr($bitsequence,17,7));
    $val = "T: $temp H: $hum B: $bat";
  }
  elsif ($model eq "03") {      # PEARL NC7159, LogiLink WS0002
  #                 /--------------------------------- Sensdortype      
  #                /    / ---------------------------- ID, changes after every battery change      
  #               /    /        /--------------------- Battery state 0 == Ok
  #              /    /        /  / ------------------ forced send      
  #             /    /        /  /  / ---------------- Channel (0..2)      
  #            /    /        /  /  /  / -------------- neg Temp: if 1 then temp = temp - 2048
  #           /    /        /  /  /  /   / ----------- Temp
  #          /    /        /  /  /  /   /          /-- unknown
  #         /    /        /  /  /  /   /          /  / Humidity
  #         0101 00101001 0  0  00 0  01000110000 1  1011101
  # Bit     0    4        12 13 14 16 17          28 29    36
    $SensorTyp = "NC_WS";
    $channel = bin2dec(substr($bitsequence,14,2));
    $bin = substr($bitsequence,4,8);
    $deviceCode = sprintf('%X', oct("0b$bin"));
    $bat = int(substr($bitsequence,12,1)) eq "1" ? "ok" : "critical";
    $trend = "";
    $sendMode = int(substr($bitsequence,13,1)) eq "0" ? "automatic" : "manual";
    $temp = bin2dec(substr($bitsequence,17,11));
    if (substr($bitsequence,16,1) eq "1") {
      $temp = $temp - 2048;
    }
    $temp = $temp / 10.0;
    $hum = bin2dec(substr($bitsequence,29,7));
    $val = "T: $temp H: $hum B: $bat";
   }
  elsif ($model eq "04") {      # Lifetec
    $SensorTyp = "Lifetec";
    $bitsequence = substr($bitsequence,0,24); # Only 24 Bits
    $channel = "";
    $bin = substr($bitsequence,0,8);
    $deviceCode = sprintf('%X', oct("0b$bin"));
    $bat = int(substr($bitsequence,16,1)) eq "1" ? "ok" : "critical";
    $trend = "";
    $sendMode = int(substr($bitsequence,17,1)) eq "0" ? "automatic" : "manual";
    $temp = bin2dec(substr($bitsequence,9,7));
    $temp = $temp + (bin2dec(substr($bitsequence,20,4))/10.0);
    if (substr($bitsequence,8,1) eq "1") {
      $temp = $temp * (-1);
    }
    $hum = (-1);
    $val = "T: $temp H: $hum B: $bat";
  }
  elsif ($model eq "05") {      # TX70DTH (Aldi)
    $SensorTyp = "TX70DTH";
    $channel = bin2dec(substr($bitsequence,9,3));
    $bin = substr($bitsequence,0,8);
    $deviceCode = sprintf('%X', oct("0b$bin"));
    $bat = int(substr($bitsequence,8,1)) eq "1" ? "ok" : "critical";
    $trend = "";
    $sendMode = "";
    $temp = bin2dec(substr($bitsequence,16,8));
    if (substr($bitsequence,14,1) eq "1") {
      $temp = $temp - 1024;
    }
    $hum = bin2dec(substr($bitsequence,29,7));
    $val = "T: $temp H: $hum B: $bat";
  }
  elsif ($model eq "06") {      # AURIOL (Lidl Version: 09/2013)
  #                /--------------------------------- Channel, changes after every battery change      
  #               /        / ------------------------ Battery state 1 == Ok      
  #              /        / /------------------------ Battery changed, Sync startet      
  #             /        / /  ----------------------- Unknown      
  #            /        / / /  /--------------------- neg Temp: if 1 then temp = temp - 4096
  #           /        / / /  /---------------------- 12 Bit Temperature
  #          /        / / /  /            /---------- ??? CRC 
  #         /        / / /  /            /      /---- Trend 10 == rising, 01 == falling
  #         01010101 1 0 00 000100001011 110001 00
  # Bit     0        8 9 10 12           24     30
    $SensorTyp = "AURIOL";
    $bitsequence = substr($bitsequence,0,32); # Only 32 Bits
    $channel = "0";
    $bin = substr($bitsequence,0,8);
    $deviceCode = sprintf('%X', oct("0b$bin"));
    if (int(substr($bitsequence,9,1)) eq "1") {
      Log3 $hash, 1, "FHEMduino_Env $SensorTyp: Battery changed -> New DeviceCode: $deviceCode";
      return "";
    }
    $channel = "0";
    $bin = substr($bitsequence,0,8);
    $deviceCode = sprintf('%X', oct("0b$bin"));
    $bat = int(substr($bitsequence,8,1)) eq "1" ? "ok" : "critical";
    $tmp = bin2dec(substr($bitsequence,30,2));
    if (int($tmp) == 2)
    {
      $trend = "rising";
    }
    elsif (int($tmp) == 1)
    {
      $trend = "falling";
    }
    else
    {
      $trend = "stable";
    }    
    $sendMode = "";
    $temp = bin2dec(substr($bitsequence,12,12));
    if (substr($bitsequence,12,1) eq "1") {
      $temp = $temp - 4096;
    }
    $temp = $temp / 10.0;
    $hum = (-1);
    $val = "T: $temp H: $hum B: $bat";
  }
  elsif ($model eq "07") {      # Auriol2
		# see http://www.tfd.hu/tfdhu/files/wsprotocol/auriol_protocol_v20.pdf for a protocol description
    $SensorTyp = "Auriol_H13726";
    $bin = binflip(substr($bitsequence,0,8));
    $deviceCode = sprintf('%X', oct("0b$bin"));
    $bat = int(substr($bitsequence,8,1)) eq "0" ? "ok" : "critical";
    $sendMode = int(substr($bitsequence,11,1)) eq "0" ? "automatic" : "manual";
    $channel = '';
    $trend = "";
    $val = '';

		my $checknibble = bin2dec(binflip(hex2bin(substr($hextext,8,1)))); #binflip(substr($bitsequence,32,4));
		my $cs;
		$temp = '?';
		$hum = (-1);
		$val = '';
		    
    my $msgType;
    if (substr($bitsequence,9,2) eq '11' && substr($bitsequence,12,4) eq '1100') {
			# rain sensor
      $msgType = "rain $hextext";
			
			# test checksum
			$cs = crosssum(substr($hextext,0,8), 1);
			if (((0x7 + $cs) & 0xf) != $checknibble ) {
				Log3 $hash, 2, "FHEMduino_Env Auriol2 checksum mismatch $msgType";
				return "";
			}

			if (substr($bitsequence,12,3) eq '110') {
				$rain = unpack("v",pack("b16",substr($bitsequence,16,16))) * 0.25 - 0.25;
				$val = 'R: $rain';  
			}
	  } else {
			# combined sensor, three different packets from the same sensor id

			# test checksum
			$cs = crosssum(substr($hextext,0,8), -1);
			if (((0xf + $cs) & 0xf) != $checknibble ) {
				Log3 $hash, 2, "FHEMduino_Env Auriol2 combined sensor checksum mismatch $hextext";
				return "";
			}
			
			if (substr($bitsequence,9,2) eq '11') {
        # wind
        $msgType = "wind ";
        if (substr($bitsequence,12,3) eq '100') {
          $msgType .= "speed $hextext";
          if (substr($bitsequence,15,9) ne '000000000') {
            # invalid value
            Log3 $hash, 2, "FHEMduino_Env Auriol2 invalid value $msgType";
            return "";
          }
          $windspeed = unpack("C",pack("b8",substr($bitsequence,24,8))) * 0.2;
          if ($windspeed > 30) {
              # invalid value
              Log3 $hash, 2, "FHEMduino_Env Auriol2 invalid value $msgType";
              return "";
          }
        } elsif (substr($bitsequence,12,3) eq '111') {
          $msgType .= "direction/gust $hextext";
          $winddirection = unpack("v",pack("b9",substr($bitsequence,15,9)));
          $windgust = unpack("C",pack("b8",substr($bitsequence,24,8))) * 0.2;
          if (!$winddirection2compass{$winddirection}) {
            # invalid value
            Log3 $hash, 2, "FHEMduino_Env Auriol2 invalid value $msgType";
            return "";
          }
        } else {
            # invalid value
            Log3 $hash, 2, "FHEMduino_Env Auriol2 invalid value $msgType";
            return "";
        }
			} else {
        # temp/hum
    	  $msgType = "temp/hum $hextext";
				$temp = twocompl2dec(substr($bitsequence,12,12));
				$hum = bin2dec(binflip(substr($bitsequence,28,4))) . bin2dec(binflip(substr($bitsequence,24,4)));
				if ($hum < 20 || $hum > 99 || $temp < -20 || $temp > 60) {
            # invalid value
            Log3 $hash, 2, "FHEMduino_Env Auriol2 invalid value $msgType";
            return "";
				}
			}
			$val = 'T: $temp H: $hum';
 			$val .= ' S: $windspeed ';
			$val .= ' D: $winddirection G: $windgust';
	  }

		$val .= ' B: $bat';

	  #$msgType .= " " . $val;
    Log3 $hash, 3, "FHEMduino_Env Auriol2 $msgType";
		
  }
  else {
    Log3 $hash, 1, "FHEMduino_Env unknown model: $model $msg";
	return "";
  }

  if ($channel ne "") {
    $deviceCode = $deviceCode."_".$channel;
  }
  
  my $def = $modules{FHEMduino_Env}{defptr}{$hash->{NAME} . "." . $deviceCode};
  $def = $modules{FHEMduino_Env}{defptr}{$deviceCode} if(!$def);
  
  if(!$def) {
    Log3 $hash, 1, "FHEMduino_Env: UNDEFINED sensor $SensorTyp detected, code $deviceCode";
    return "UNDEFINED $SensorTyp"."_"."$deviceCode FHEMduino_Env $deviceCode";
  }

  $hash = $def;
  my $name = $hash->{NAME};
  return "" if(IsIgnored($name));
  
  Log3 $name, 4, "FHEMduino_Env: $name ($msg)";  
  
  if($hash->{lastReceive} && (time() - $hash->{lastReceive} < $def->{minsecs} )) {
    if (($def->{lastMSG} ne $msg) && ($def->{equalMSG} > 0)) {
      Log3 $name, 4, "FHEMduino_Env: $name: $deviceCode no skipping due unequal message even if to short timedifference";
    } else {
      Log3 $name, 4, "FHEMduino_Env: $name: $deviceCode Skipping due to short timedifference";
      return "";
    }
  }

  if(!$val) {
    Log3 $name, 1, "FHEMduino_Env: $name: $deviceCode Cannot decode $msg";
    return "";
  }
  
  if ($hash->{lastReceive} && (time() - $hash->{lastReceive} < 300)) {
		if ($temp ne '?') {
			if ($hash->{lastValues} && $hash->{lastValues}{temperature} && $hash->{lastValues}{temperature} ne '?' && (abs(abs($hash->{lastValues}{temperature}) - abs($temp)) > 5)) {
				Log3 $name, 4, "FHEMduino_Env: $name: $deviceCode Temperature jump too large";
				return "";
			}
		}
    if ($hum >= 0) {
      if ($hash->{lastValues} && $hash->{lastValues}{humidity} && $hash->{lastValues}{humidity} ne '?' && (abs(abs($hash->{lastValues}{humidity}) - abs($hum)) > 5)) {
        Log3 $name, 4, "FHEMduino_Env: $name: $deviceCode Humidity jump too large";
        return "";
      }
	}
  }
  else {
    Log3 $name, 4, "FHEMduino_Env: $name: $deviceCode Skipping override due to too large timedifference";
  }

  $hash->{lastReceive} = time();
  if ($temp ne '?') {
		$hash->{lastValues}{temperature} = $temp;
	}
  my ($af, $td);
  if ($hum >= 0 && $temp ne '?') {
    $hash->{lastValues}{humidity} = $hum;
    # TD = Taupunkttemperatur in °C 
    # AF = absolute Feuchte in g Wasserdampf pro m3 Luft
    ($af, $td) = af_td($temp, $hum);
    $hash->{lastValues}{taupunkttemp} = $td;
    $hash->{lastValues}{abshum} = $af;
  }
  $def->{lastMSG} = $msg;
  $def->{bitMSG} = $bitsequence;

  Log3 $name, 4, "FHEMduino_Env $name: $val";
  

  readingsBeginUpdate($hash);
  if ($temp eq '?') {
   	$temp = ReadingsVal($name, 'temperature', '?');
  } else {
		readingsBulkUpdate($hash, "temperature", $temp);
	}
  if ($hum >= 0) {
    readingsBulkUpdate($hash, "humidity", $hum);
    readingsBulkUpdate($hash, "taupunkttemp", $td);
    readingsBulkUpdate($hash, "abshum", $af);
  } else {
		$hum = ReadingsVal($name, 'humidity', -1);  
  }
  if ($bat ne "") {
    readingsBulkUpdate($hash, "battery", $bat);
  }
  if ($trend ne "") {
    readingsBulkUpdate($hash, "trend", $trend);
  }
  if ($sendMode ne "") {
    readingsBulkUpdate($hash, "sendMode", $sendMode);
  }

	if ($winddirection eq '?') {
		$winddirection = ReadingsVal($name, 'wind_direction', '?');
	} else {
		readingsBulkUpdate($hash, "wind_direction", $winddirection);
		if ($winddirection2compass{$winddirection}) {
			readingsBulkUpdate($hash, "wind_compasspoint", $winddirection2compass{$winddirection});
		}
	}
	if ($windspeed eq '?') {
		$windspeed = ReadingsVal($name, 'wind_speed', '?');
	} else {
		readingsBulkUpdate($hash, "wind_speed", $windspeed);
		$bft = windspeed2bft($windspeed);
    readingsBulkUpdate($hash, "wind_speed_bft", $bft);
    readingsBulkUpdate($hash, "wind_speed_bft_text", $bft2text{$bft});
		
	}
	if ($windgust eq '?') {
		$windgust = ReadingsVal($name, 'wind_gust', '?');
	} else {
		readingsBulkUpdate($hash, "wind_gust", $windgust);
    $bft = windspeed2bft($windgust);
    readingsBulkUpdate($hash, "wind_gust_bft", $bft);
    readingsBulkUpdate($hash, "wind_gust_bft_text", $bft2text{$bft});
  }
  if ($rain eq '?') {
		$rain = ReadingsVal($name, 'rain', '?');  
	} else {
		readingsBulkUpdate($hash, "rain", $rain);
	}

	
  # interpolate the variables in $val now, see http://bioinfo2.ugr.es/documentation/Perl_Cookbook/ch01_09.htm
  $val =~ s/(\$\w+)/$1/eeg;
  readingsBulkUpdate($hash, "state", $val);
	
  readingsEndUpdate($hash, 1); # Notify is done by Dispatch

  return $name;
}

sub
FHEMduino_Env_Attr(@)
{
  my @a = @_;

  # Make possible to use the same code for different logical devices when they
  # are received through different physical devices.
  return if($a[0] ne "set" || $a[2] ne "IODev");
  my $hash = $defs{$a[1]};
  my $iohash = $defs{$a[3]};
  my $cde = $hash->{CODE};
  delete($modules{FHEMduino_Env}{defptr}{$cde});
  $modules{FHEMduino_Env}{defptr}{$iohash->{NAME} . "." . $cde} = $hash;
  return undef;
}

sub
af_td ($$)
{
# Formeln von http://www.wettermail.de/wetter/feuchte.html

# r = relative Luftfeuchte
# T = Temperatur in °C

my ($T, $rh) = @_;

# a = 7.5, b = 237.3 für T >= 0
# a = 9.5, b = 265.5 für T < 0 über Eis (Frostpunkt)  
        my $a = ($T > 0) ? 7.5 : 9.5;
        my $b = ($T > 0) ? 237.3 : 265.5;

# SDD = Sättigungsdampfdruck in hPa  
# SDD(T) = 6.1078 * 10^((a*T)/(b+T))
  my $SDD = 6.1078 * 10**(($a*$T)/($b+$T));
# DD = Dampfdruck in hPa
# DD(r,T) = r/100 * SDD(T)
  my $DD  = $rh/100 * $SDD;  
# AF(r,TK) = 10^5 * mw/R* * DD(r,T)/TK; AF(TD,TK) = 10^5 * mw/R* * SDD(TD)/TK
# R* = 8314.3 J/(kmol*K) (universelle Gaskonstante)
# mw = 18.016 kg (Molekulargewicht des Wasserdampfes)
# TK = Temperatur in Kelvin (TK = T + 273.15)
  my $AF  = (10**5) * (18.016 / 8314.3) * ($DD / (273.15 + $T));
  my $af  = sprintf( "%.1f",$AF); # Auf eine Nachkommastelle runden

 # TD(r,T) = b*v/(a-v) mit v(r,T) = log10(DD(r,T)/6.1078)  
  my $v   =  log10($DD/6.1078);
  my $TD  = $b*$v/($a-$v);
  my $td  = sprintf( "%.1f",$TD); # Auf eine Nachkommastelle runden

# TD = Taupunkttemperatur in °C 
# AF = absolute Feuchte in g Wasserdampf pro m3 Luft 
  return($af, $td);
  
}

#sub 
#log10 {
#        my $n = shift;
#        return log($n)/log(10);
#}

sub
hex2bin($)
{
  my $h = shift;
  my $hlen = length($h);
  my $blen = $hlen * 4;
  return unpack("B$blen", pack("H$hlen", $h));
}

sub
bin2dec($)
{
  my $h = shift;
  my $int = unpack("N", pack("B32",substr("0" x 32 . $h, -32))); 
  return sprintf("%d", $int); 
}

sub
binflip($)
{
  my $h = shift;
  my $hlen = length($h);
  my $i = 0;
  my $flip = "";
  
  for ($i=$hlen-1; $i >= 0; $i--) {
    $flip = $flip.substr($h,$i,1);
  }

  return $flip;
}

sub
twocompl2dec($)
{
  my $h = shift;
  

  #Log3 "FHEMduino_Env", 1, "temp bits " . $h;
  my $int = unpack("V", pack("b32",$h . "00000000")); 
  #Log3 "FHEMduino_Env", 1, "temp value " . $int;
  
  if ($int & 0b100000000000) {
		# negative number
		$int--;
		$int = ~$int;
		$int = -$int;
	}
  return $int / 10.0; 
}

sub crosssum($$) {
	my $h = shift;
	my $factor = shift;
	my $sum = 0;
	my $c;
	
	foreach $c (split("",$h)) {
		$c = bin2dec(binflip(hex2bin($c)));
		$sum += $c * $factor;
	}
	return $sum;
}

sub windspeed2bft($) {
  #
  #  convert m/s to bft as described by
  #  http://www.meteotest.ch/wetterprognosen/prognosen_schweiz/windtabelle
  #
  my ($w) = shift;
  return  "0" if($w <= 0.2);
  return  "1" if($w >  0.2 && $w <=  1.5);
  return  "2" if($w >  1.5 && $w <=  3.3);
  return  "3" if($w >  3.3 && $w <=  5.4);
  return  "4" if($w >  5.4 && $w <=  7.9);
  return  "5" if($w >  7.9 && $w <=  10.7);
  return  "6" if($w >  10.7 && $w <=  13.8);
  return  "7" if($w >  13.8 && $w <=  17.1);
  return  "8" if($w >  17.1 && $w <=  20.7);
  return  "9" if($w >  20.7 && $w <=  24.4);
  return "10" if($w >  24.4 && $w <=  28.4);
  return "11" if($w >  28.4 && $w <=  32.6);
  return "12" if($w > 32.6);
}

1;

=pod
=begin html

<a name="FHEMduino_Env"></a>
<h3>FHEMduino_Env</h3>
<ul>
  The FHEMduino_Env module interprets LogiLink Env type of messages received by the FHEMduino.
  <br><br>

  <a name="FHEMduino_Envdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; FHEMduino_Env &lt;code&gt; [minsecs] [equalmsg]</code> <br>

    <br>
    &lt;code&gt; is the housecode of the autogenerated address of the Env device and 
	is build by the channelnumber (1 to 3) and an autogenerated address build when including
	the battery (adress will change every time changing the battery).<br>
    minsecs are the minimum seconds between two log entries or notifications
    from this device. <br>E.g. if set to 300, logs of the same type will occure
    with a minimum rate of one per 5 minutes even if the device sends a message
    every minute. (Reduces the log file size and reduces the time to display
    the plots)<br>
	equalmsg set to 1 generates, if even if minsecs is set, a log entrie or notification
	when the msg content has changed.
  </ul>
  <br>

  <a name="FHEMduino_Envset"></a>
  <b>Set</b> <ul>N/A</ul><br>

  <a name="FHEMduino_Envget"></a>
  <b>Get</b> <ul>N/A</ul><br>

  <a name="FHEMduino_Envattr"></a>
  <b>Attributes</b>
  <ul>
    <li><a href="#IODev">IODev (!)</a></li>
    <li><a href="#do_not_notify">do_not_notify</a></li>
    <li><a href="#eventMap">eventMap</a></li>
    <li><a href="#ignore">ignore</a></li>
    <li><a href="#model">model</a> (LogiLink Env)</li>
    <li><a href="#showtime">showtime</a></li>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li>
  </ul>
  <br>
</ul>

=end html

=begin html_DE

<a name="FHEMduino_Env"></a>
<h3>FHEMduino_Env</h3>
<ul>
  Das FHEMduino_Env module dekodiert vom FHEMduino empfangene Nachrichten des LogiLink Env.
  <br><br>

  <a name="FHEMduino_Envdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; FHEMduino_Env &lt;code&gt; [minsecs] [equalmsg]</code> <br>

    <br>
    &lt;code&gt; ist der automatisch angelegte Hauscode des Env und besteht aus der
	Kanalnummer (1..3) und einer Zufallsadresse, die durch das Gerät beim einlegen der
	Batterie generiert wird (Die Adresse ändert sich bei jedem Batteriewechsel).<br>
    minsecs definert die Sekunden die mindesten vergangen sein müssen bis ein neuer
	Logeintrag oder eine neue Nachricht generiert werden.
    <br>
	Z.B. wenn 300, werden Einträge nur alle 5 Minuten erzeugt, auch wenn das Device
    alle paar Sekunden eine Nachricht generiert. (Reduziert die Log-Dateigröße und die Zeit
	die zur Anzeige von Plots benötigt wird.)<br>
	equalmsg gesetzt auf 1 legt fest, dass Einträge auch dann erzeugt werden wenn die durch
	minsecs vorgegebene Zeit noch nicht verstrichen ist, sich aber der Nachrichteninhalt geändert
	hat.
  </ul>
  <br>

  <a name="FHEMduino_Envset"></a>
  <b>Set</b> <ul>N/A</ul><br>

  <a name="FHEMduino_Envget"></a>
  <b>Get</b> <ul>N/A</ul><br>

  <a name="FHEMduino_Envattr"></a>
  <b>Attributes</b>
  <ul>
    <li><a href="#IODev">IODev (!)</a></li>
    <li><a href="#do_not_notify">do_not_notify</a></li>
    <li><a href="#eventMap">eventMap</a></li>
    <li><a href="#ignore">ignore</a></li>
    <li><a href="#model">model</a> (LogiLink Env)</li>
    <li><a href="#showtime">showtime</a></li>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li>
  </ul>
  <br>
</ul>

=end html_DE
=cut
