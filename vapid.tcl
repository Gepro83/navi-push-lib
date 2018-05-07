package require uri

#
# Test file for VAPID token generation
# RFC 8292: Voluntary Application Server Identification (VAPID)
#

set ::vapidCertPath "[ns_info home]/modules/vapid"
set ::testSuite "[ns_info home]/pages/pushnotificationsapi/TestSuite.tcl"

if {![file exists $::vapidCertPath/prime256v1_key.pem]} {
    #
    # create private key for vapid
    #
    if {[catch {
	file mkdir $::vapidCertPath
    }]} {
	ns_log notice "insufficient permissions for NaviServer to crate directory $::vapidCertPath"
	ns_log notice "probably the following command will help:\nsudo chown nsadmin [ns_info home]/modules/"
    } else {
	cd $::vapidCertPath
	ns_log notice ".... creating private_key.pem"
	exec -ignorestderr openssl ecparam -genkey -name prime256v1 -out prime256v1_key.pem
    }
}
if {![file exists $::vapidCertPath/public_key.txt]} {
    cd $::vapidCertPath
    ns_log notice ".... extracting .txt files"
    exec -ignorestderr openssl ec -in prime256v1_key.pem -pubout -outform DER | tail -c 65 | base64 | tr -d '=' | tr '/+' '-_' > public_key.txt
    exec -ignorestderr openssl ec -in prime256v1_key.pem -outform DER | tail -c +8 | head -c 32 | base64 | tr -d '=' | tr '/+' '-_' > private_key.txt
}

proc stripWhitespacesNewlines {str} {
  return [string map {" " {} \n {}} $str]
}

proc vapidToken {string} {
    set signature [::ns_crypto::md vapidsign -digest sha256 -encoding base64url -pem $::vapidCertPath/prime256v1_key.pem $string]
    return $string.$signature
}

#
#  webpush
#
#  send a push notification to the specified substription endpoint
#
#  subscribtion is expected to be a dict that includes at least an "endpoint"
#  for data bearing subscriptions the key field needs to be set aswell
#  this is an example of a json formatted subscribtion:
# {
#   "endpoint":"https://updates.push.services.mozilla.com/wpush/v2/gAAAA...",
#   "keys":{
#     "auth":"5DqpICDCHSi..",
#     "p256dh":"BFECk9GdfDOJOzx.."
#   }
# }
#
# claim is a dict containing at least a "sub" field that contains a "mailto:example@example.org" email adress
# the "aud" of the claim will be extracted from the endpoint if not provided
# "exp" will be set to +24hours from the time of the function call if not provided
#
# private_key is the path to a pem file containing a VAPID EC private key
#
# timeout is the timeout parameter of the push message (post request)
#
# ttl is the time to live of the push message
proc webpush {subscription data claim private_key {timeout 2.0} {ttl 0}} {
  # validate subscription
  if {[dict exists $subscription endpoint]} {
      set endpoint [dict get $subscription endpoint]
  } else {
    error "No endpoint information provided!"
  }
  # validate private key and create public key in base64 encoded DER format
  set public_key [getPublicKey $private_key]
  # validate/fill claim
  set claim [validateClaim $claim $endpoint]
  # create a signed jwt token
  set jwt [makeJWT $claim $private_key]
  # create vapid-03 Authorization header
  set authorization [subst {vapid t=$jwt,k=$public_key}]
  set headers [ns_set create]
  ns_set update $headers Authorization $authorization
  ns_set update $headers TTL $ttl
  # queue the request
  set req [ns_http queue -method POST \
     -headers $headers \
     -timeout $timeout \
     $endpoint]
  set replyHeaders [ns_set create]
  # wait for answer of push service and record reply
  ns_http wait -result result -headers $replyHeaders -status status $req
  if {$status > 202} {
    error "Webpush failed!" $result $status
  }
  return $status
}

#
# takes the path to a pem file of an SECP256 private key and
# creates a dervied public key
#
# throws an exception if the file does not exist or is a wrong format
#
# returns the public key in base64 encoded DER format
proc getPublicKey {private_key_pem} {
  if {![file exists $private_key_pem]} {
    error "$private_key_pem does not exist!"
  }
  if {[catch {
        set pubkey [string map {\n {}}\
        [exec -ignorestderr openssl ec -in $private_key_pem -pubout -outform DER | tail -c 65 | base64 | tr -d '=' | tr '/+' '-_']]
        }]} {
    error "$private_key_pem not a valid private key pem file"
  }
  return $pubkey
}

#
# validates the contents of a claim and fills the "aud" and "exp" fields if not present
# validates the "aud" field against the endpoint
# set the "exp" field to a correct value if it is wrong
#
# returns a valid claim as a dict or throws an exception
proc validateClaim {claim endpoint} {
  # validate 'sub'
  if {[dict exists $claim sub]} {
    set mail [::uri::split [dict get $claim sub]]
    if {[dict get $mail scheme] ne "mailto"} {
      error "'sub' must be of form 'mailto:...@...'"
    }
  } else {
    error "claim must contain 'sub'"
  }
  # validate/add 'aud'
  array set endPointArr [::uri::split $endpoint]
  if {[dict exists $claim aud]} {
    array set aud [::uri::split [dict get $claim aud]]
    if {
      $endPointArr(scheme) ne $aud(scheme) ||
      $endPointArr(host) ne $aud(host) ||
      $endPointArr(port) ne $aud(port)
      } {
      error "'aud' of claim does not match endpoint"
    }
  } else {
    if {$endPointArr(port) eq ""} {
      dict set claim aud [::uri::join scheme $endPointArr(scheme) host $endPointArr(host)]
    } else {
      dict set claim aud [::uri::join scheme $endPointArr(scheme) host $endPointArr(host) port $endPointArr(port)]
    }
  }
  # validate/add exp
  if {[dict exists $claim exp]} {
    set exp [dict get $claim exp]
    if {
      ![string is integer $exp] ||
      [expr $exp < [clock seconds]] ||
      [expr $exp > ([clock seconds] + 60*60*24)]} {
      dict set claim exp [expr [clock seconds] + 59*60*24]
    }
  } else {
    dict set claim exp [expr [clock seconds] + 59*60*24]
  }
  return $claim
}

# takes a claim and the path to an EC private key and creates a
# signed JWT token
# whitespaces and newlines are stripped from the claim
proc makeJWT {claim private_key_pem} {
  # this is always the jwt header
  set JWTHeader [ns_base64urlencode {{"typ":"JWT","alg":"ES256"}}]
  # reformat claim dict to json
  set JWTbody [ns_base64urlencode [dictToJson $claim]]

  set signature [::ns_crypto::md vapidsign -digest sha256\
   -encoding base64url -pem $private_key_pem $JWTHeader.$JWTbody ]
  return $JWTHeader.$JWTbody.$signature
}

# serializes a dict to json
# no testing for nested dicts or arrays, these will be simply added as a string
# the json is in compact form,
# meaning no whitespaces and newlines between keys/values
proc dictToJson {dict} {
  set retJson "{"
  dict for {key value} $dict {
    append retJson [subst {"$key":"$value",}]
  }
  return [string range $retJson 0 end-1]}
}




set claim [subst {
  {
  "sub" : "mailto:h0325904@wu.ac.at",
  "aud" : "https://updates.push.services.mozilla.com/",
  "exp" : "[expr [clock seconds] + 60*120]"
  }
}]

# the JWT base string is the header and body separated with a "."
set JWTHeader [ns_base64urlencode {{"typ":"JWT","alg":"ES256"}}]
set JWTbody [ns_base64urlencode [stripWhitespacesNewlines $claim]]

set token [vapidToken $JWTHeader.$JWTbody]
ns_log notice "VAPID token: <$token>"

set f [open $::vapidCertPath/public_key.txt]
set pub_key [read $f]
close $f

set f [open $::vapidCertPath/private_key.txt]
set priv_key [read $f]
close $f

set f [open $::vapidCertPath/prime256v1_key.pem]
set pem [read $f]
close $f

source $::testSuite

ns_return 200 text/plain [subst {
    claim:
    $claim

    unsigned: $JWTHeader.$JWTbody

    VAPID token: $token
    VAPID token length: [string length $token]

    $::vapidCertPath/prime256v1_key.pem - [file size $::vapidCertPath/prime256v1_key.pem] bytes
    $::vapidCertPath/public_key.txt     - [file size $::vapidCertPath/public_key.txt] bytes
    $::vapidCertPath/private_key.txt    - [file size $::vapidCertPath/private_key.txt] bytes

    public_key : [string trim $pub_key]
    private_key: [string trim $priv_key]

    prime256v1_key.pem\n$pem

    HOME: $::env(HOME)
}]
