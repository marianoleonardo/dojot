local BasePlugin = require "kong.plugins.base_plugin"
local jwt_decoder = require "kong.plugins.jwt.jwt_parser"
local http = require "socket.http"
local https = require "ssl.https"

local build_form_params = require("kong.plugins.pepkong.utils").build_form_params

local re_gmatch = ngx.re.gmatch

----------- Load environment variables ---------------
local env_ssl_ca_file = "DOJOT_PLUGIN_SSL_CAFILE"
local env_ssl_verify = "DOJOT_PLUGIN_SSL_VERIFY"
local env_ssl_cert_file = "DOJOT_PLUGIN_SSL_CERTFILE"
local env_ssl_key_file = "DOJOT_PLUGIN_SSL_KEYFILE"
local env_request_timeout = "DOJOT_PLUGIN_REQUEST_TIMEOUT"

local ssl_ca_file = os.getenv(env_ssl_ca_file)
local ssl_cert_file = os.getenv(env_ssl_cert_file)
local ssl_key_file = os.getenv(env_ssl_key_file)
local ssl_verify = os.getenv(env_ssl_verify)

------------------------------------------------------

----------- configure timeout for requests -----------
local request_timeout = os.getenv(env_request_timeout)

if (request_timeout) then
    http.TIMEOUT = tonumber(request_timeout)
    https.TIMEOUT = tonumber(request_timeout)
else
    http.TIMEOUT = 1
    https.TIMEOUT = 1
end
-------------------------------------------------------

local pepKongHandler = BasePlugin:extend()

function pepKongHandler:new()
    pepKongHandler.super.new(self, "pepkong")
end

local function retrieve_token()

    local authorization_header = kong.request.get_header("authorization")
    if authorization_header then
        local iterator, iter_err = re_gmatch(authorization_header, "\\s*[Bb]earer\\s+(.+)")
        if not iterator then
            return nil, iter_err
        end

        local m, err = iterator()
        if err then
            return nil, err
        end

        if m and #m > 0 then
            return m[1]
        end
    end
    return kong.response.exit(401, { message = "Missing JWT token" })
end

-- Use Keycloak authorization services to make authorization decision
local function do_authorization(conf)

    -- Retrieve token
    local token, err = retrieve_token()
    if err then
        kong.log.err(err)
        return kong.response.exit(500, {
            message = "An unexpected error occurred"
        })
    end

    -- Decode token
    local jwt, err = jwt_decoder:new(token)
    if err then
        return false, {
            status = 401,
            message = "Bad token; " .. tostring(err)
        }
    end

    -- Invoke PDP/Keycloak
    local params = build_form_params(conf.resource, conf.scopes[kong.request.get_method()])
    local token_endpoint = jwt.claims.iss .. "/protocol/openid-connect/token"

    local protocol = string.sub(token_endpoint, 0, 5)

    kong.log.debug('Invoke PDP/Keycloak in endpoint: ', token_endpoint)
    kong.log.debug('Invoke PDP/Keycloak with params: ', params)

    local response = {}

    local header_request = {
        ["Authorization"] = "Bearer " .. token,
        ["Content-Type"] = "application/x-www-form-urlencoded",
        ["Accept"] = 'application/json',
        ["content-length"] = string.len(params)
    }

    local source_request = ltn12.source.string(params)
    local method_request = "POST"
    local sink_request = ltn12.sink.table(response)

    local base_request = {
        method = method_request,
        url = token_endpoint,
        source = source_request,
        headers = header_request,
        sink = sink_request
    }

    local do_request

    -- This lib "ssl.https" doesn't use certificate verification as we explicitly specified
    -- base_request['verify']="none" in the parameter list. Certificate verification allows the client
    -- (this script in this case) to confirm that the site it is connected to has access
    -- to a valid certificate, signed by a certificate authority.
    -- This is the same process that your web browser does for you
    -- when you connect to a website over https. To enable certificate
    -- verification in SSL verify="none" needs to be replaced with verify="peer" or "client_once".
    -- This is not enough, however: if you run this code with verify="peer" or "client_once",
    -- you will get: `certificate verify failed error`.
    -- This error indicates that we requested certificate verification,
    -- but have no means to verify this certificate as we don't have any certificate
    -- authority certificates we can use to validate the signature on
    -- the certificate provided by the website we are connecting to.
    -- To do that, we need to find and download the file with these certificates;
    -- it comes with your browser, but can also be found online.
    -- For example, this internal cert from kong "/etc/ssl/certs/ca-certificates.crt"
    -- I was loading an internal kong base_request['cafile']="/etc/ssl/certs/ca-certificates.crt" and verify="peer",
    -- but that was what I was doing greatly increase the memory
    -- consumption of the kong container, reaching more than 1 gb without decreasing. We have to think about how to solve this.
    -- https://github.com/brunoos/luasec/wiki
    -- https://github.com/brunoos/luasec/wiki/LuaSec-1.0.x

    if protocol == "https" then
        if (ssl_ca_file) then
            base_request['cafile']=ssl_ca_file
        end

        if (ssl_cert_file) then
            base_request['certificate']=ssl_cert_file
        end

        if (ssl_key_file) then
            base_request['key']=ssl_key_file
        end

        if (ssl_verify) then
            base_request['verify']=ssl_verify
        end

        base_request['protocol']="any"
        base_request['options']= { "all",
            -- disable this protocols bellow
            "no_sslv2",
            "no_sslv3",
            "no_tlsv1",
            "no_tlsv1_1"
        }

        do_request = https.request

    else
        do_request = http.request
    end

    local body, code, headers, status = do_request (base_request)

    local message = response[1]

    if code ~= 200 then

        kong.log.err('Error when trying to check permission on keycloak')
        kong.log.debug('...status=', status)
        kong.log.debug('...code=', code)

        if (type(code) ~= "number") then
            code = 500
        end

        return false, {
            status = code,
            message = message
        }
    end

    return true

end

function pepKongHandler:access(conf)
    pepKongHandler.super.access(self)

    -- validate if the request is valid
    if not conf.scopes[kong.request.get_method()] then
        return kong.response.exit(405)
    end

    local ok, err = do_authorization(conf)
    if not ok then
        return kong.response.exit(err.status, err.message)
    end

end

return pepKongHandler
