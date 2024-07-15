^https?:\/\/(9521732\.xyz|.*\.9521732\.xyz|embyplus\.org|.*\.embyplus\.org|chirsemby\.top|.*\.chirsemby\.top)\/ url request-header (\r\n)X-Emby-Authorization: Emby UserId="([^\"]+)", Client="VidHub_iOS", Device="([^\"]+)", DeviceId="([^\"]+)", Version="1.7.2"(\r\n) request-header $1X-Emby-Authorization: Emby UserId="$3", Client="SenPlayer", Device="$4", DeviceId="$5", Version="4.0.9"$6
^https?:\/\/(9521732\.xyz|.*\.9521732\.xyz|embyplus\.org|.*\.embyplus\.org|chirsemby\.top|.*\.chirsemby\.top)\/ url request-header (\r\n)User-Agent: VidHub\/2024071203 CFNetwork\/1496\.0\.7 Darwin\/23\.5\.0(\r\n) request-header $1User-Agent: SenPlayer/4.0.9$3


[MITM]
hostname = 9521732.xyz, *.9521732.xyz, embyplus.org, *.embyplus.org, chirsemby.top, *.chirsemby.top
