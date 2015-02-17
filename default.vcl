vcl 4.0;
# Based on: https://github.com/mattiasgeniar/varnish-4.0-configuration-templates/blob/master/default.vcl
# Corrected & improved for 4.0.2 by jnerin@gmail.com
import std; 
import directors;
backend server1 { # Define one backend
	.host = "127.0.0.1"; # IP or Hostname of backend
	.port = "80"; # Port Apache or whatever is listening
	.max_connections = 300; # That's it
	.probe = {
		#.url = "/"; # short easy way (GET /)
		# We prefer to only do a HEAD /
		.request = 
			"HEAD / HTTP/1.1"
			"Host: localhost"
			"Connection: close";      	
		.interval = 5s; # check the health of each backend every 5 seconds
		.timeout = 1s; # timing out after 1 second.
		# If 3 out of the last 5 polls succeeded the backend is considered healthy, otherwise it will be marked as sick
		.window = 5;
		.threshold = 3;
		}
	.first_byte_timeout     = 300s;   # How long to wait before we receive a first byte from our backend?
	.connect_timeout        = 5s;     # How long to wait for a backend connection?
	.between_bytes_timeout  = 2s;     # How long to wait between bytes received from our backend?
}
acl purge {
# ACL we'll use later to allow purges
	"localhost";
	"127.0.0.1";
	"::1";
}

/*
acl editors {
# ACL to honor the "Cache-Control: no-cache" header to force a refresh but only from selected IPs
	"localhost";
	"127.0.0.1";
	"::1";	
}
*/

sub vcl_init {
# Called when VCL is loaded, before any requests pass through it. Typically used to initialize VMODs.

	new vdir = directors.round_robin();
	vdir.add_backend(server1);
	# vdir.add_backend(server...);
	# vdir.add_backend(servern);
}

sub vcl_recv {
# Called at the beginning of a request, after the complete request has been received and parsed. Its purpose is to decide whether or not to serve the request, how to do it, and, if applicable, which backend to use.
# also used to modify the request

	set req.backend_hint = vdir.backend(); # send all traffic to the vdir director

	# Not needed now
#	if (req.restarts == 0) {
#		if (req.http.X-Forwarded-For) { # set or append the client.ip to X-Forwarded-For header
#			set req.http.X-Forwarded-For = req.http.X-Forwarded-For + ", " + client.ip;
#		} else {
#			set req.http.X-Forwarded-For = client.ip;
#		}
#	}

	# Normalize the header, remove the port (in case you're testing this on various TCP ports)
	set req.http.Host = regsub(req.http.Host, ":[0-9]+", "");
	
	# Normalize the query arguments
	set req.url = std.querysort(req.url);

	# Sample permanent redirect
	#if (req.http.host ~ "^www.example.com$") {
	#	return(synth(720, "http://example.com" + req.url));
	#}

	# Allow purging & other non-standar methods to evict cache contents
	if (req.method == "PURGE") {
		if (!client.ip ~ purge) { # purge is the ACL defined at the begining
			# Not from an allowed IP? Then die with an error.
			return (synth(405, "This IP is not allowed to send PURGE requests."));
		}
		# If you got this stage (and didn't error out above), purge the cached result
		return (purge);
	}

        if (req.request == "REFRESH") {
		if (!client.ip ~ purge) { # purge is the ACL defined at the begining
			# Not from an allowed IP? Then die with an error.
			return (synth(405, "This IP is not allowed to send REFRESH requests."));
		}
		# If you got this stage (and didn't error out above), purge the cached result
                set req.request = "GET";
                set req.hash_always_miss = true;
        }

	if (req.request == "BAN") {
	# See https://www.varnish-software.com/static/book/Cache_invalidation.html#smart-bans
		if (!client.ip ~ purge) { # purge is the ACL defined at the begining
			# Not from an allowed IP? Then die with an error.
			return (synth(405, "This IP is not allowed to send BAN requests."));
		}
		# If you got this stage (and didn't error out above), purge the cached result

                ban("obj.http.x-url ~ " + req.http.x-ban-url +
                    " && obj.http.x-host ~ " + req.http.x-ban-host);
                error 200 "Banned";
        }


	# Only deal with "normal" types
	if (req.method != "GET" &&
			req.method != "HEAD" &&
			req.method != "PUT" &&
			req.method != "POST" &&
			req.method != "TRACE" &&
			req.method != "OPTIONS" &&
			req.method != "PATCH" &&
			req.method != "DELETE") {
		/* Non-RFC2616 or CONNECT which is weird. */
		return (pipe);
	}

	# Implementing websocket support (https://www.varnish-cache.org/docs/4.0/users-guide/vcl-example-websockets.html)
	if (req.http.Upgrade ~ "(?i)websocket") {
        	return (pipe);
     	}

	# Only cache GET or HEAD requests. This makes sure the POST requests are always passed.
	if (req.method != "GET" && req.method != "HEAD") {
		return (pass);
	}

	# Some generic URL manipulation, useful for all templates that follow
	# First remove the Google Analytics added parameters, useless for our backend
	if (req.url ~ "(\?|&)(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=") {
		set req.url = regsuball(req.url, "&(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "");
		set req.url = regsuball(req.url, "\?(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "?");
		set req.url = regsub(req.url, "\?&", "?");
		set req.url = regsub(req.url, "\?$", "");
	}

	# Strip hash, server doesn't need it.
	if (req.url ~ "\#") {
		set req.url = regsub(req.url, "\#.*$", "");
	}

	# Strip a trailing ? if it exists
	if (req.url ~ "\?$") {
		set req.url = regsub(req.url, "\?$", "");
	}

	# Some generic cookie manipulation, useful for all templates that follow
	# Remove the "has_js" cookie
	set req.http.Cookie = regsuball(req.http.Cookie, "has_js=[^;]+(; )?", "");

	# Remove any Google Analytics based cookies
	set req.http.Cookie = regsuball(req.http.Cookie, "__utm.=[^;]+(; )?", "");
	set req.http.Cookie = regsuball(req.http.Cookie, "_ga=[^;]+(; )?", "");
	set req.http.Cookie = regsuball(req.http.Cookie, "utmctr=[^;]+(; )?", "");
	set req.http.Cookie = regsuball(req.http.Cookie, "utmcmd.=[^;]+(; )?", "");
	set req.http.Cookie = regsuball(req.http.Cookie, "utmccn.=[^;]+(; )?", "");

	# Remove the Quant Capital cookies (added by some plugin, all __qca)
	set req.http.Cookie = regsuball(req.http.Cookie, "__qc.=[^;]+(; )?", "");

	# Remove the AddThis cookies
	set req.http.Cookie = regsuball(req.http.Cookie, "__atuvc=[^;]+(; )?", "");

	# Remove a ";" prefix in the cookie if present
	set req.http.Cookie = regsuball(req.http.Cookie, "^;\s*", "");

	# Are there cookies left with only spaces or that are empty?
	if (req.http.cookie ~ "^\s*$") {
		unset req.http.cookie;
	}

	# Normalize Accept-Encoding header
	# straight from the manual: https://www.varnish-cache.org/docs/3.0/tutorial/vary.html
	# TODO: Test if it's still needed, Varnish 4 now does this by itself if http_gzip_support = on
	# https://www.varnish-cache.org/docs/trunk/users-guide/compression.html
	# https://www.varnish-cache.org/docs/trunk/phk/gzip.html
	if (req.http.Accept-Encoding) {
		if (req.url ~ "\.(jpg|png|gif|gz|tgz|bz2|tbz|mp3|ogg)$") {
			# No point in compressing these
			unset req.http.Accept-Encoding;
		} elsif (req.http.Accept-Encoding ~ "gzip") {
			set req.http.Accept-Encoding = "gzip";
		} elsif (req.http.Accept-Encoding ~ "deflate") {
			set req.http.Accept-Encoding = "deflate";
		} else {
			# unkown algorithm
			unset req.http.Accept-Encoding;
		}
	}

	if (req.http.Cache-Control ~ "(?i)no-cache") { 
	#if (req.http.Cache-Control ~ "(?i)no-cache" && client.ip ~ editors) { # create the acl editors if you want to restrict the Ctrl-F5
	# http://varnish.projects.linpro.no/wiki/VCLExampleEnableForceRefresh
	# Ignore requests via proxy caches and badly behaved crawlers
	# like msnbot that send no-cache with every request.
		if (! (req.http.Via || req.http.User-Agent ~ "(?i)bot" || req.http.X-Purge)) {
			#set req.hash_always_miss = true; # Doesn't seems to refresh the object in the cache
			return(purge); # Couple this with restart in vcl_purge and X-Purge header to avoid loops
		}
	}

	# Large static files are delivered directly to the end-user without
	# waiting for Varnish to fully read the file first.
	# Varnish 4 fully supports Streaming, so set do_stream in vcl_backend_response()
	if (req.url ~ "^[^?]*\.(mp[34]|rar|tar|tgz|gz|wav|zip|bz2|xz|7z|avi|mov|ogm|mpe?g|mk[av])(\?.*)?$") {
		unset req.http.Cookie;
		return (hash);
	}

	# Remove all cookies for static files
	# A valid discussion could be held on this line: do you really need to cache static files that don't cause load? Only if you have memory left.
	# Sure, there's disk I/O, but chances are your OS will already have these files in their buffers (thus memory).
	# Before you blindly enable this, have a read here: http://mattiasgeniar.be/2012/11/28/stop-caching-static-files/
	if (req.url ~ "^[^?]*\.(bmp|bz2|css|doc|eot|flv|gif|gz|ico|jpeg|jpg|js|less|pdf|png|rtf|swf|txt|woff|xml)(\?.*)?$") {
		unset req.http.Cookie;
		return (hash);
	}

	# Send Surrogate-Capability headers to announce ESI support to backend
	set req.http.Surrogate-Capability = "key=ESI/1.0";

	if (req.http.Authorization) {
		# Not cacheable by default
		return (pass);
	}

	return (hash);
}

sub vcl_pipe {
# Called upon entering pipe mode. In this mode, the request is passed on to the backend, and any further data from both the client and backend is passed on unaltered until either end closes the connection. Basically, Varnish will degrade into a simple TCP proxy, shuffling bytes back and forth. For a connection in pipe mode, no other VCL subroutine will ever get called after vcl_pipe.

	# Note that only the first request to the backend will have
	# X-Forwarded-For set.  If you use X-Forwarded-For and want to
	# have it set for all requests, make sure to have:
	# set bereq.http.connection = "close";
	# here.  It is not set by default as it might break some broken web
	# applications, like IIS with NTLM authentication.

	#set bereq.http.Connection = "Close";

	# Implementing websocket support (https://www.varnish-cache.org/docs/4.0/users-guide/vcl-example-websockets.html)
     	if (req.http.upgrade) {
        	set bereq.http.upgrade = req.http.upgrade;
     	}

	return (pipe);
}

sub vcl_pass {
# Called upon entering pass mode. In this mode, the request is passed on to the backend, and the backend's response is passed on to the client, but is not entered into the cache. Subsequent requests submitted over the same client connection are handled normally.

	# return (pass);
}

# The data on which the hashing will take place
sub vcl_hash {
# Called after vcl_recv to create a hash value for the request. This is used as a key to look up the object in Varnish.

	hash_data(req.url);

	if (req.http.host) {
		hash_data(req.http.host);
	} else {
		hash_data(server.ip);
	}

	# hash cookies for requests that have them
	if (req.http.Cookie) {
		hash_data(req.http.Cookie);
	}
}

sub vcl_hit {
# Called when a cache lookup is successful.

	if (obj.ttl >= 0s) {
		# A pure unadultered hit, deliver it
		return (deliver);
	}

	# https://www.varnish-cache.org/docs/trunk/users-guide/vcl-grace.html
	# When several clients are requesting the same page Varnish will send one request to the backend and place the others on hold while fetching one copy from the backend. In some products this is called request coalescing and Varnish does this automatically.
	# If you are serving thousands of hits per second the queue of waiting requests can get huge. There are two potential problems - one is a thundering herd problem - suddenly releasing a thousand threads to serve content might send the load sky high. Secondly - nobody likes to wait. To deal with this we can instruct Varnish to keep the objects in cache beyond their TTL and to serve the waiting requests somewhat stale content.

#	if (!std.healthy(req.backend_hint) && (obj.ttl + obj.grace > 0s)) {
#		return (deliver);
#	} else {
#		return (fetch);
#	}

	# We have no fresh fish. Lets look at the stale ones.
	if (std.healthy(req.backend_hint)) {
		# Backend is healthy. Limit age to 10s.
	    	if (obj.ttl + 10s > 0s) {
      			#set req.http.grace = "normal(limited)";
      			return (deliver);
	    	} else {
      			# No candidate for grace. Fetch a fresh object.
			return(fetch);
	   	}
	} else {
		# backend is sick - use full grace
    		if (obj.ttl + obj.grace > 0s) {
      			#set req.http.grace = "full";
			return (deliver);
		} else {
			# no graced object.
			return (fetch);
		}
	}


	# fetch & deliver once we get the result
	return (fetch);	# Dead code, keep as a safeguard
}

sub vcl_miss {
# Called after a cache lookup if the requested document was not found in the cache. Its purpose is to decide whether or not to attempt to retrieve the document from the backend, and which backend to use.

	return (fetch);
}

# Handle the HTTP request coming from our backend
sub vcl_backend_response {
# Called after the response headers has been successfully retrieved from the backend.

	# Add headers to allow smart bans
	set beresp.http.x-url = req.url;
	set beresp.http.x-host = req.http.host;

	# Pause ESI request and remove Surrogate-Control header
	if (beresp.http.Surrogate-Control ~ "ESI/1.0") {
		unset beresp.http.Surrogate-Control;
		set beresp.do_esi = true;
	}

	# Enable cache for all static files
	# The same argument as the static caches from above: monitor your cache size, if you get data nuked out of it, consider giving up the static file cache.
	# Before you blindly enable this, have a read here: http://mattiasgeniar.be/2012/11/28/stop-caching-static-files/
	if (bereq.url ~ "^[^?]*\.(bmp|bz2|css|doc|eot|flv|gif|gz|ico|jpeg|jpg|js|less|mp[34]|pdf|png|rar|rtf|swf|tar|tgz|txt|wav|woff|xml|zip)(\?.*)?$") {
		unset beresp.http.set-cookie;
	}


	# Large static files are delivered directly to the end-user without
	# waiting for Varnish to fully read the file first.
	# Varnish 4 fully supports Streaming, so use streaming here to avoid locking.
	if (bereq.url ~ "^[^?]*\.(mp[34]|rar|tar|tgz|gz|wav|zip|bz2|xz|7z|avi|mov|ogm|mpe?g|mk[av])(\?.*)?$") {
		unset beresp.http.set-cookie;		
		set beresp.do_stream = true; 	# Check memory usage it'll grow in fetch_chunksize blocks (128k by default) if 
						# the backend doesn't send a Content-Length header, so only enable it for big objects
		set beresp.do_gzip = false;	# Don't try to compress it for storage
	}

	# Sometimes, a 301 or 302 redirect formed via Apache's mod_rewrite can mess with the HTTP port that is being passed along.
	# This often happens with simple rewrite rules in a scenario where Varnish runs on :80 and Apache on :8080 on the same box.
	# A redirect can then often redirect the end-user to a URL on :8080, where it should be :80.
	# This may need finetuning on your setup.
	#
	# To prevent accidental replace, we only filter the 301/302 redirects for now.
	if (beresp.status == 301 || beresp.status == 302) {
		set beresp.http.Location = regsub(beresp.http.Location, ":[0-9]+", "");
	}

	# Set 2min cache if unset for static files
	if (beresp.ttl <= 0s || beresp.http.Set-Cookie || beresp.http.Vary == "*") {
		set beresp.ttl = 120s; # Important, you shouldn't rely on this, SET YOUR HEADERS in the backend
		set beresp.uncacheable = true;
		return (deliver);
	}

	# Allow stale content, in case the backend goes down.
	# make Varnish keep all objects for 6 hours beyond their TTL
	set beresp.grace = 6h;

	return (deliver);
}

# The routine when we deliver the HTTP request to the user
# Last chance to modify headers that are sent to the client
sub vcl_deliver {
# Called before a cached object is delivered to the client.

	# Remove the headers that allow smart bans before sending to client
	unset resp.http.x-url;
	unset resp.http.x-host;

	if (obj.hits > 0) { # Add debug header to see if it's a HIT/MISS and the number of hits, disable when not needed
		set resp.http.X-Cache = "HIT";
	} else {
		set resp.http.X-Cache = "MISS";
	}
	# Please note that obj.hits behaviour changed in 4.0, now it counts per objecthead, not per object
	# and obj.hits may not be reset in some cases where bans are in use. See bug 1492 for details.
	# So take hits with a grain of salt
	set resp.http.X-Cache-Hits = obj.hits;

	# Remove some headers: PHP version
	unset resp.http.X-Powered-By;

	# Remove some headers: Apache version & OS
	unset resp.http.Server;
	unset resp.http.X-Drupal-Cache;
	unset resp.http.X-Varnish;
	unset resp.http.Via;
	unset resp.http.Link;

	return (deliver);
}

sub vcl_purge {
    # return (synth(200, "Purged")); # by default in builtin.vcl
}

sub vcl_synth {
	if (resp.status == 720) {
		# We use this special error status 720 to force redirects with 301 (permanent) redirects
		# To use this, call the following from anywhere in vcl_recv: return(synth(720, "http://host/new.html")
		set resp.http.Location = resp.reason;
		set resp.status = 301; # Be careful to set it after using resp.reason or it'll overwrite it
		return (deliver);
	} elseif (resp.status == 721) {
		# And we use error status 721 to force redirects with a 302 (temporary) redirect
		# To use this, call the following from anywhere in vcl_recv: return(synth(721, "http://host/new.html")
		set resp.http.Location = resp.reason;
		set resp.status = 302; # Be careful to set it after using resp.reason or it'll overwrite it
		return (deliver);
	}

	return (deliver);
}


sub vcl_fini {
# Called when VCL is discarded only after all requests have exited the VCL. Typically used to clean up VMODs.

	return (ok);
}
