-- resty.aws

local resty_hmac = require('resty.hmac')
local resty_sha256 = require('resty.sha256')
local str = require('resty.string')

local _M = { _VERSION = '0.1.3' }

local function get_iso8601_basic(timestamp)
  return os.date('!%Y%m%dT%H%M%SZ', timestamp)
end

local function get_iso8601_basic_short(timestamp)
  return os.date('!%Y%m%d', timestamp)
end

local function get_derived_signing_key(keys, timestamp, region, service)
  local h_date = resty_hmac:new('AWS4' .. keys['secret_key'], resty_hmac.ALGOS.SHA256)
  h_date:update(get_iso8601_basic_short(timestamp))
  local k_date = h_date:final()

  local h_region = resty_hmac:new(k_date, resty_hmac.ALGOS.SHA256)
  h_region:update(region)
  local k_region = h_region:final()

  local h_service = resty_hmac:new(k_region, resty_hmac.ALGOS.SHA256)
  h_service:update(service)
  local k_service = h_service:final()

  local h = resty_hmac:new(k_service, resty_hmac.ALGOS.SHA256)
  h:update('aws4_request')
  return h:final()
end

local function get_cred_scope(timestamp, region, service)
  return get_iso8601_basic_short(timestamp)
    .. '/' .. region
    .. '/' .. service
    .. '/aws4_request'
end

local function get_signed_headers()
  return 'host;x-amz-content-sha256;x-amz-date'
end

local function get_sha256_digest(s)
  local h = resty_sha256:new()
  h:update(s or '')
  return str.to_hex(h:final())
end

local function get_canonical_query_string()
  local args = ngx.req.get_uri_args()
  local query_string = ''
  for key, val in pairs(args) do
    if query_string ~= '' then
      query_string = query_string .. '&'
    end

    if type(val) == "table" then
      query_string = query_string .. key .. '=' .. val[0] --Get the first instance of said argument, ignore the others. (Note: Maybe we should just include all instances of said parameter?)
    else
      query_string = query_string .. key .. '=' .. val
    end
  end

  return query_string
end

local function get_hashed_canonical_request(timestamp, host, uri)
  local digest
  if ngx.var.request_body == nil and ngx.var.request_method == 'PUT' then
    digest = 'UNSIGNED-PAYLOAD'
  else
    digest = get_sha256_digest(ngx.var.request_body)
  end
  local canonical_request = 
    ngx.var.request_method .. '\n' 
    .. uri .. '\n' 
    .. get_canonical_query_string() .. '\n' 
    .. 'host:' .. host .. '\n' 
    .. 'x-amz-content-sha256:' .. digest .. '\n'
    .. 'x-amz-date:' .. get_iso8601_basic(timestamp) .. '\n'
    .. '\n'
    .. get_signed_headers() .. '\n'
    .. digest
  return get_sha256_digest(canonical_request)
end

local function get_string_to_sign(timestamp, region, service, host, uri)
  return 'AWS4-HMAC-SHA256\n'
    .. get_iso8601_basic(timestamp) .. '\n'
    .. get_cred_scope(timestamp, region, service) .. '\n'
    .. get_hashed_canonical_request(timestamp, host, uri)
end

local function get_signature(derived_signing_key, string_to_sign)
  local h = resty_hmac:new(derived_signing_key, resty_hmac.ALGOS.SHA256)
  h:update(string_to_sign)
  return h:final(nil, true)
end

local function get_authorization(keys, timestamp, region, service, host, uri)
  local derived_signing_key = get_derived_signing_key(keys, timestamp, region, service)
  local string_to_sign = get_string_to_sign(timestamp, region, service, host, uri)
  local auth = 'AWS4-HMAC-SHA256 '
    .. 'Credential=' .. keys['access_key'] .. '/' .. get_cred_scope(timestamp, region, service)
    .. ', SignedHeaders=' .. get_signed_headers()
    .. ', Signature=' .. get_signature(derived_signing_key, string_to_sign)
  return auth
end

local function get_service_and_region(host)
  local patterns = {
    {'s3.amazonaws.com', 's3', 'us-east-1'},
    {'s3-external-1.amazonaws.com', 's3', 'us-east-1'},
    {'s3%.([a-z0-9-]+)%.amazonaws%.com', 's3', nil},
    {'s3%-([a-z0-9-]+)%.amazonaws%.com', 's3', nil}
  }

  for i,data in ipairs(patterns) do
    local region = host:match(data[1])
    if region ~= nil and data[3] == nil then
      return data[2], region
    elseif region ~= nil then
      return data[2], data[3]
    end
  end

  return nil, nil
end

function _M.aws_set_headers(access_key, secret_key, host, uri, region, service)
  local creds = {
    access_key = access_key,
    secret_key = secret_key
  }
  local timestamp = tonumber(ngx.time())
  if region == nil or service == nil then
    service, region = get_service_and_region(host)
  end
  local auth = get_authorization(creds, timestamp, region, service, host, uri)

  ngx.req.set_header('Authorization', auth)
  ngx.req.set_header('Host', host)
  ngx.req.set_header('x-amz-date', get_iso8601_basic(timestamp))
end

function _M.s3_set_headers(access_key, secret_key, host, uri, region, service)
  _M.aws_set_headers(access_key, secret_key, host, uri, region, service)
  if ngx.var.request_body == nil and ngx.var.request_method == 'PUT' then
    ngx.req.set_header('x-amz-content-sha256', 'UNSIGNED-PAYLOAD')
  else
    ngx.req.set_header('x-amz-content-sha256', get_sha256_digest(ngx.var.request_body))
  end
end

return _M