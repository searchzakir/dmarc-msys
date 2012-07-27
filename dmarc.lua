--
-- DMARC parsing validating and reporting
-- 
--[[ Copyright 2012 Linkedin

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
]]
-- version 1.3
--

--[[ This requires the dp_config.lua scripts to contain a dmarc entry
--that will specify whitelists when the policy should not be applied.
--ruf  to enable sending forensic reports, if there is an email, reports
--will be sent to this address regarding of the domain policy,
--if external is false no report is sent but to the email address.

-- DMARC check
msys.dp_config.dmarc = {
    ruf = {
    enable = true,
    email = "dmarc@example.com",
    external = false
  },
  local_policy = {
    check = true,
    honor_whitelist = { "whitelist" }
  },
  trusted_forwarder = {
    check = true,
    honor_whitelist = { "whitelist" }
  },
  mailing_list = {
    check = true,
    honor_whitelist = { "whitelist" }
  }
};

The following functions are required in custom_policy.lua, 
this will load domains that pass dkim in dmarc_dkim_domains
and all the domains that have a DKIM-Signature header
note: ec_dkim_domains returns the domain in i= if found otherwise d= 

function msys.dp_config.custom_policy.pre_validate_data(msg, ac, vctx)
-- the following has a memory leak so we use a sieve script instead
--  local domains = msys.validate.dkim.get_domains(msg, vctx);
--  vctx:set(msys.core.VCTX_MESS, "dmarc_dkim_domains",domains);
-- siv-begin
-- $domains = ec_dkim_domains;
--
-- if isset $domains 0 {
--   $domains_string = join " " $domains;
-- } else {
--   $domains_string = "";
-- }
-- 
-- vctx_mess_set "dmarc_dkim_domains" $domains_string;
-- siv-end
-- 
--  
  --- see if there are DKIM headers in the message                                 
  local dkim_domains ="";
  local dkim_domainsi = "";
  local dk=msg:header('DKIM-Signature');
  local ddomain = "";
  local idomain = "";
  for k,v in pairs(dk) do
    print ("DKIM:"..tostring(v));
    ddomain ="";
    idomain = ""
    dke = explode(";",v);
    for i=0,#dke do
      -- print ("dke:"..tostring(dke[i]));
      if string.sub(dke[i],2,3) == "d=" then
         ddomain = string.lower(string.sub(dke[i],4));
      end
      if string.sub(dke[i],2,3) == "i=" then
         local itag = string.lower(string.sub(dke[i],4));
         local var = msys.pcre.match(itag,"^.*@(?<domain>\\w+)$");
         if var then
           idomain = var["domain"];
         end
      end
    end
    dkim_domains =  dkim_domains .. " " .. ddomain;
    if idomain ~= "" then
      dkim_domainsi =  dkim_domainsi .. " " .. idomain;
    else
      dkim_domainsi =  dkim_domainsi .. " " .. ddomain;
    end
  end  
  vctx:set(msys.core.VCTX_MESS, "dkim_domains",dkim_domains);
  vctx:set(msys.core.VCTX_MESS, "dkim_domainsi",dkim_domainsi);
  
  local ret = dmarc_validate_data(msg, ac, vctx);

  if ret == nil then
  	ret=msys.core.VALIDATE_CONT;
  end
  
  return ret;
end

]]

require("msys.pbp");
require("msys.core");
require("dp_config");
require("msys.validate.dkim");
require("msys.extended.vctx");
require("msys.extended.message");

local mod = {};
local jlog;
local debug = true;

-- explode(seperator, string)
local function explode(d,p)
  local t, ll, i
  t={[0]=""}
  ll=0
  i=0;
  if(#p == 1) then return {p} end
    while true do
      l=string.find(p,d,ll,true) -- find the next d in the string
      if l~=nil then -- if "not not" found then..
        t[i] = string.sub(p,ll,l-1); -- Save it in our array.
        ll=l+1; -- save just after where we found it for searching next time.
        i=i+1;
      else
        t[i] = string.sub(p,ll); -- Save what's left in our array.
        break -- Break at end, as it should be, according to the lua manual.
      end
    end
  return t
end

-- IPv4 and IPv6
local function ip_from_addr_and_port(addr_and_port)
  local ip="UNKNOWN";
  if debug then print("addr_and_port"..tostring(addr_and_port)); end
  if addr_and_port ~= nil then
    ip = string.match(addr_and_port, "(.*):%d");
  end
  if ip == nil then
    print("can't decode:"..tostring(addr_and_port));
    ip="UNKNOWN";
  end
  if debug then print("ip"..tostring(ip)); end
  return ip;
end

local function dmarc_log(report)
  if debug then print("dmarc_log"); end
  if (jlog == nil) then
    jlog = msys.core.io_wrapper_open("jlog:///var/log/ecelerity/dmarclog.cluster=>master", msys.core.O_CREAT | msys.core.O_APPEND | msys.core.O_WRONLY, 0660);
  end
  jlog:write(report,string.len(report));
  if debug then print("end of dmarc_log");end
end

local function dmarc_find(domain)
  local dmarc_found = false;
  local dmarc_record = "";
  local results, errmsg = msys.dnsLookup("_dmarc." .. tostring(domain), "txt");
  if results ~= nil then
    for k,v in ipairs(results) do
      if string.sub(v,1,8) == "v=DMARC1" then
        dmarc_found = true;
        dmarc_record = v;
        break;
      end
    end
  end
  return dmarc_found, dmarc_record;
end

local function dmarc_search(from_domain)
  -- Now let's find if the domain has a DMARC record.
  local dmarc_found = false;
  local dmarc_record = "";
      
  local t = msys.pcre.split(string.lower(from_domain), "\\.");
  local domain;
  local domain_policy = false;
  if t ~= nil and #t >= 2 then
    domain = string.lower(from_domain);
    dmarc_found, dmarc_record = dmarc_find(domain);
    if dmarc_found == false then
      for j=math.min(#t-2,4),1,-1 do
        if j==1 then
          domain = t[#t - 1] .. "." .. t[#t];
          dmarc_found, dmarc_record = dmarc_find(domain);
          if dmarc_found then
            break;
          end        
        end
        if j==2 then
          domain = t[#t - 2] .. "." .. t[#t - 1] .. "." .. t[#t];
          dmarc_found, dmarc_record = dmarc_find(domain);
          if dmarc_found then
            break;
          end
        end
        if j==3 then
          domain = t[#t - 3] .. "." .. t[#t - 2] .. "." .. t[#t - 1] .. "." .. t[#t];
          dmarc_found, dmarc_record = dmarc_find(domain);
          if dmarc_found then
            break;
          end
        end
        if j==4 then
          domain = t[#t - 4] .. "." .. t[#t - 3] .. "." .. t[#t - 2] .. "." .. t[#t - 1] .. "." .. t[#t];
          dmarc_found, dmarc_record = dmarc_find(domain);
          if dmarc_found then
            break;
          end
        end
      end
    else
      domain_policy = true;
    end
  end

  if debug and dmarc_found then 
    print("dmarc_record:"..tostring(dmarc_record));
    print("domain:"..tostring(domain));
    print("domain_policy:"..tostring(domain_policy));
  end  
  return dmarc_found,dmarc_record,domain,domain_policy;
end

local function ruf_mail_list(ruf,domain)
        local maillist="";
        if msys.dp_config.dmarc.ruf.email ~= nil then
        	maillist=msys.dp_config.dmarc.ruf.email..",";
        end
        if msys.dp_config.dmarc.ruf.external==nil or msys.dp_config.dmarc.ruf.external==false then
		maillist=string.sub(maillist,1,-2);
		return maillist;
        end
	if ruf==nil or ruf=="" then
		return maillist;
	end
	local kv_pairs = msys.pcre.split(ruf, "\\s*,\\s*");
	for k, v in ipairs(kv_pairs) do
      local ruflocal,rufdomain = string.match(v, "mailto:%s*(.+)@(.+)");
      ruflocal = string.lower(tostring(ruflocal));
      rufdomain = string.lower(tostring(rufdomain));
      if debug then print ("ruf:"..ruflocal.."@"..rufdomain); end
      if string.find("."..rufdomain, "."..domain, 1, true) ~=nil then
      	maillist=maillist..ruflocal.."@"..rufdomain..",";
      else
        local results, errmsg = msys.dnsLookup(domain.."_report._dmarc." .. tostring(rufdomain), "txt");
  		if results ~= nil then
   		  for k2,v2 in ipairs(results) do
      		if string.sub(v2,1,8) == "v=DMARC1" then
              maillist=maillist..ruflocal.."@"..rufdomain..",";
              break;
      	    end
          end
        end
      end
    end
	maillist=string.sub(maillist,1,-2);
	return maillist;
end

local function dmarc_forensic(ruf,domain,dmarc_status, ip, msg)
	local maillist = ruf_mail_list(ruf,domain);
	if debug then print("ruf mail list:"..maillist); end
	if maillist==nil or maillist=="" then
		return msys.core.VALIDATE_CONT;
	end	
	-- get the mesage ready to be sent
	
	local headers = {};
	
	local imsg = msys.core.ec_message_new(now);
	local imailfrom = "dmarc-noreply@linkedin.com";
	local mailfrom = msg:mailfrom();
	local rcptto = msg:rcptto();
	local msgidtbl = msg:header("Message-Id");
        local msgid = "";
        if msgidtbl ~= nil and #msgidtbl>=1 then
           msgid = msgidtbl[1];
        end
	local today = os.date("%a, %d %b %Y %X %z")
	
	headers["To"] = maillist;
	headers["From"] = "dmarc-noreply@linkedin.com";
	headers["Subject"] = "Forensic report";
		
	local parttext = "Content-Type: text/plain; charset=\"US-ASCII\"\r\n"..
					 "Content-Transfer-Encoding: 7bit\r\n\r\n"..
					 "This is an email abuse report for an email message received from IP "..tostring(ip).." on "..tostring(today)..".\r\n"..
					 "The message below did not meet the sending domain's dmarc policy.\r\n"..
					 "For more information about this format please see http://tools.ietf.org/html/rfc6591 .\r\n\r\n";

	local partfeedback = "Content-Type: message/feedback-report\r\n\r\n"..
	                     "Feedback-Type: auth-failure\r\n"..
						 "User-Agent: Lua/1.0\r\n"..
						 "Version: 1.0\r\n"..
						 "Original-Mail-From: "..tostring(mailfrom).."\r\n"..
						 "Original-Rcpt-To: "..tostring(rcptto).."\r\n"..
						 "Arrival-Date: "..today.."\r\n"..
						 "Message-ID: "..tostring(msgid).."\r\n"..
						 "Authentication-Results: "..tostring(dmarc_status).."\r\n"..
						 "Source-IP: "..tostring(ip).."\r\n"..
						 "Delivery-Result: reject\r\n"..
						 "Auth-Failure: dmarc\r\n"..
						 "Reported-Domain: "..tostring(domain).."\r\n\r\n";
	
	---- build message
	-- insert headers
	local io = msys.core.ec_message_builder(imsg,2048);
  	-- write the headers
  	local boundary = imsg:makeBoundary();
  	local len_boundary = #boundary;
  	local k,v;
  	for k,v in pairs(headers) do
          if string.lower(k) != "content-type" and v != nil then
            io:write(k, #k);
            io:write(": ", 2);
            io:write(v, #v);
            io:write("\r\n", 2);
          end
       end
       local tmp = "Content-Type: multipart/report; report-type=feedback-report;\r\n    boundary=\""..boundary.."\"\r\n";
       io:write(tmp, #tmp);

       io:write("\r\n", 2);
	
       -- first boundary: text
       io:write("--", 2);
       io:write(boundary, len_boundary);
       io:write("\r\n", 2);
    
       io:write(parttext, #parttext);
    
        -- second boundary: feedback report
    
	io:write("--", 2);
        io:write(boundary, len_boundary);
        io:write("\r\n", 2);
    
        io:write(partfeedback, #partfeedback);
    
        -- third boundary: attached email
        io:write("--", 2);
        io:write(boundary, len_boundary);
        io:write("\r\n", 2);
    
        io:write("Content-Type: message/rfc822\r\n", 30);
        io:write("Content-Disposition: inline\r\n\r\n", 31);

	local tmp_str = msys.core.string_new();
        tmp_str.type = msys.core.STRING_TYPE_IO_OBJECT;
        tmp_str.backing = io;
        msg:render_to_string(tmp_str, msys.core.EC_MSG_RENDER_OMIT_DOT);
    
	io:write("\r\n--", 4)
        io:write(boundary, len_boundary)
        io:write("--\r\n", 4)
    
        -- end of the message
        io:write("\r\n.\r\n", 5)
        io:close()
        io = nil

	imsg:inject(imailfrom, maillist);

        if debug then print("ruf sent"); end
	return msys.core.VALIDATE_CONT;
										
end

local function dmarc_work(msg, ac, vctx, from_domain, envelope_domain, dmarc_found, dmarc_record, domain, domain_policy)
  if debug and dmarc_found then
    print("from_domain",from_domain);
    print("envelope_domain",envelope_domain);
  end

  -- Check SPF and alignment
  local spf_alignement = "none";
  local spf_status = vctx:get(msys.core.VCTX_MESS, "spf_status");
  if debug and dmarc_found then print("spf_status",spf_status); end
  if spf_status ~= nil and spf_status == "pass" then
    if from_domain == envelope_domain then
      spf_alignement="strict";
    elseif string.find("."..from_domain, "."..envelope_domain, 1, true) ~=nil or 
           string.find("."..envelope_domain, "."..from_domain, 1, true) ~=nil then
      spf_alignement = "relaxed";
    end    
  end
  if debug and dmarc_found then print("spf_alignement",spf_alignement); end
  
  -- Check DKIM and alignment
  local dkim_alignement = "none";
  if debug and dmarc_found then print("dmarc_dkim_domains:"..tostring(vctx:get(msys.core.VCTX_MESS, "dmarc_dkim_domains"))); end
  local dkim_domains = msys.pcre.split(vctx:get(msys.core.VCTX_MESS, "dmarc_dkim_domains"), "\\s+");
  for k, dkim_domain in ipairs(dkim_domains) do
    if dkim_domain == from_domain then
      dkim_alignement = "strict";
      break;
    elseif string.find("."..from_domain, "."..dkim_domain, 1, true) ~=nil or 
           string.find("."..dkim_domain, "."..from_domain, 1, true) ~=nil then
      dkim_alignement = "relaxed";
    end        
  end
  if debug and dmarc_found then print("dkim_alignement",dkim_alignement); end

  local real_pairs = {};
  if dmarc_found then
    local kv_pairs = msys.pcre.split(dmarc_record, "\\s*;\\s*")   
    for k, v in ipairs(kv_pairs) do
      local key, value = string.match(v, "([^=%s]+)%s*=%s*(.+)");
      local key = string.lower(key);
      real_pairs[key] = value;
      if debug then print(key.."="..value); end
    end
  end
  
  local dmarc_status;
  -- no policy enforcement bail out but give a status.
  if dmarc_found == false or real_pairs.v == nil or real_pairs.v ~= "DMARC1" or
     real_pairs.p == nil then     
    if spf_alignement ~= "none" or dkim_alignement ~= "none" then
      dmarc_status = "dmarc=pass d=" .. tostring(from_domain) .. " (p=nil; dis=none)";
    else
      dmarc_status = "dmarc=fail d=" .. tostring(from_domain) .. " (p=nil; dis=none)";
    end
    if debug then print(dmarc_status); end
    vctx:set(msys.core.VCTX_MESS, "dmarc_status",dmarc_status);
    return msys.core.VALIDATE_CONT;
  end
  
  -- find if we have DMARC pass with all the options
  local dmarc_spf = "fail";
  local dmarc_dkim = "fail";
  if real_pairs.aspf == nil then
    real_pairs["aspf"] = "r";
  else
  	real_pairs["aspf"] = string.lower(real_pairs["aspf"]);
  end
  if real_pairs.adkim == nil then
    real_pairs["adkim"] = "r";
  else
  	real_pairs["adkim"] = string.lower(real_pairs["adkim"]);
  end
  if real_pairs.aspf == "r" and spf_alignement ~= "none" then
    dmarc_spf = "pass";
  end
  if real_pairs.aspf == "s" and spf_alignement == "strict" then
    dmarc_spf = "pass";
  end
  if real_pairs.adkim == "r" and dkim_alignement ~= "none" then
    dmarc_dkim = "pass";
  end
  if real_pairs.adkim == "s" and dkim_alignement == "strict" then
    dmarc_dkim = "pass";
  end
  
  local dmarc = "fail";
  if dmarc_dkim == "pass" or dmarc_spf == "pass" then
    dmarc = "pass";    
  end
  if debug then print("dmarc",dmarc,"dmarc_spf",dmarc_spf,"dmarc_dkim",dmarc_dkim); end
  
  -- time to find the policy
  local policy_requested = "none";
  local policy = "none";
  
  if debug then print("domain_policy:"..tostring(domain_policy)); end 
  if domain_policy == false and real_pairs.sp == nil then
    domain_policy = true;
  end
  
  real_pairs["p"] = string.lower(real_pairs["p"]);
  if domain_policy == true then
    if real_pairs.p=="quarantine" or real_pairs.p=="reject" then
      policy_requested = real_pairs.p;
    end
  else
    if real_pairs.sp ~= nil then
      real_pairs["sp"] = string.lower(real_pairs["sp"]);
      if real_pairs.sp=="quarantine" or real_pairs.sp=="reject" then
        policy_requested = real_pairs.sp;
      end
    end
  end 
 
  if real_pairs.p == nil then
    real_pairs["p"] = "none"
  end

  if real_pairs.sp == nil then
    real_pairs["sp"] = real_pairs.p
  end 

  policy = policy_requested;

  if real_pairs.pct == nil then
    real_pairs["pct"] = "100";
  end
  
  if dmarc == "pass" then
    policy="none";
  else 
    -- Check if the pct argument is defined.  If so, enforce it
    if real_pairs.pct ~= nil and tonumber(real_pairs.pct) < 100 then
      if math.random(100) < tonumber(real_pairs.pct) then
        -- Not our time to run, just check and log
        if real_pairs.p ~= nil then
          if real_pairs.p == "reject" then
            policy = "quarantine";
          elseif real_pairs.p == "quarantine" then
            policy = "sampled_out";
          else
            policy = "none";
          end
        end        
      end
    end

    -- dmarc whitelist check
    if msys.dp_config.dmarc.local_policy ~= nil and
       msys.dp_config.dmarc.local_policy.check == true and
       msys.pbp.check_whitelist(vctx, msys.dp_config.dmarc.local_policy) == true then
      policy = "local_policy";
    end

    if msys.dp_config.dmarc.trusted_forwarder ~= nil and
       msys.dp_config.dmarc.trusted_forwarder.check == true and
       msys.pbp.check_whitelist(vctx, msys.dp_config.dmarc.trusted_forwarder) == true then
      policy = "trusted_forwarder";
    end

    if msys.dp_config.dmarc.mailing_list ~= nil and
       msys.dp_config.dmarc.mailing_list.check == true and
       msys.pbp.check_whitelist(vctx, msys.dp_config.dmarc.mailing_list) == true then
      local mlm = msg:header('list-id');
      if mlm ~= nill and #mlm>=1 then
        policy = "mailing_list";
      end
    end
  end

    -- set the DMARC status for posterity
  dmarc_status = "dmarc="..tostring(dmarc).." d="..tostring(domain).." (p="..tostring(policy_requested).."; dis="..tostring(policy)..")";
  vctx:set(msys.core.VCTX_MESS, "dmarc_status",dmarc_status);
  if debug then print("dmarc_status",dmarc_status); end

  -- let's log in paniclog because I don't know where else to log
  local report = "DMARC1@"..tostring(msys.core.get_now_ts()).."@"..tostring(msg.id).."@"..tostring(domain).."@"..ip_from_addr_and_port(tostring(ac.remote_addr))..
                 "@"..tostring(real_pairs.adkim).."@"..tostring(real_pairs.aspf).."@"..tostring(real_pairs.p).."@"..tostring(real_pairs.sp)..
                 "@"..tostring(policy_requested).."@"..tostring(real_pairs.pct).."@"..tostring(policy).."@"..tostring(dmarc_dkim).."@"..tostring(dmarc_spf)..
                 "@"..tostring(from_domain).."@SPF@"..tostring(envelope_domain).."@"..tostring(spf_status).."@DKIM";

  if debug then print("dkim_domains:"..tostring(vctx:get(msys.core.VCTX_MESS, "dkim_domains"))); end
  local found_dkim_domains = msys.pcre.split(vctx:get(msys.core.VCTX_MESS, "dkim_domains"), "\\s+");
  local found_dkim_domainsi = msys.pcre.split(vctx:get(msys.core.VCTX_MESS, "dkim_domainsi"), "\\s+");

  if found_dkim_domainsi ~= nil and #found_dkim_domainsi >= 1 then
    for i=1,#found_dkim_domainsi do
        local found=false;
        if dkim_domains ~= nil and #dkim_domains >= 1 then
          for j=1,#dkim_domains do
            if debug then print(">"..found_dkim_domainsi[i].."<>"..dkim_domains[j].."<>"..found_dkim_domains[i].."<"); end
            if dkim_domains[j] == found_dkim_domainsi[i] then
              found=true;
            end
          end
        end
        if found then
          report = report .. "@" .. found_dkim_domains[i] .. "@pass";
        else
          report = report .. "@" .. found_dkim_domains[i] .. "@fail";
        end
    end
  else
    if dkim_domains ~= nil and #dkim_domains >= 1 then
      report = report .. "@" .. dkim_domains[1] .. "@pass";
    else
      report = report .. "@@none";
    end
  end
  report = report .."\n";
  if debug then print("report",report); end
  status,res = msys.runInPool("IO", function () dmarc_log(report); end, true);
  
  -- and now we can enforce it  
  if policy == "reject" then
    local mlm = msg:header('list-id');
    if mlm ~= nil and #mlm>=1 then
      -- we found a list-id let's note that as we may want to whitelist
      print("DMARC MLM whitelist potential "..mlm[1].." "..ip_from_addr_and_port(tostring(ac.remote_addr)));
    end
    if msys.dp_config.dmarc.ruf.enable ~= nil and
       msys.dp_config.dmarc.ruf.enable == true then
      if real_pairs["ruf"] ~= nil and real_pairs["ruf"] ~= "" then
        real_pairs["ruf"] = string.lower(real_pairs["ruf"]);
        -- we have a ruf so we could send a forensic report
    	status,res = msys.runInPool("IO", function () dmarc_forensic(real_pairs["ruf"],domain,dmarc_status, ip_from_addr_and_port(tostring(ac.remote_addr)), msg); end, true);
      end
    end
    vctx:set_code(554, "DMARC email rejected by policy");
    return msys.core.VALIDATE_DONE;
  end
  
  if debug then print("end of dmarc_work"); end
  return msys.core.VALIDATE_CONT;
end

function dmarc_validate_data(msg, ac, vctx)

  local mailfrom = msg:mailfrom();
  
  local domains = msg:address_header("From", "domain");
  
  local headerfrom = msg:header('From');
  
  -- various checks regarding dmarc
  if #headerfrom > 1 then
    return vctx:pbp_disconnect(554, "An email with more than one From: header is invalid cf RFC5322 3.6");
  end
  
  -- various checks regarding dmarc
  if domains == nil or #domains == 0 then
	  -- No From header, reject 
	  if mailfrom ~= nil and mailfrom ~= "" then
	    -- this is not a bounce
	    if #headerfrom < 1 then
	    	return vctx:pbp_disconnect(554, "Can't find a RFC5322 From: header, this is annoying with DMARC");
	    else
	  	    return vctx:pbp_disconnect(554, "RFC5322 3.6.2 requires a domain in the header From: "..tostring(headerfrom[1]));
	  	end
	  else
	    -- this is a bounce and there is no domain to tie to DMARC so bail out.
	  	return msys.core.VALIDATE_CONT;
	  end
  end
  
  if #domains > 1 then
	  return vctx:pbp_disconnect(554, "It is difficult to do DMARC with an email with too many domains in the header From: "..tostring(headerfrom[1]));
  end
  
  local from_domain = string.lower(domains[1]);
  local envelope_domain = string.lower(vctx:get(msys.core.VCTX_MESS,
                                   msys.core.STANDARD_KEY_MAILFROM_DOMAIN));
  
  -- Now let's find if the domain has a DMARC record.
  -- we do it here as it is more efficient than in the CPU pool
  local dmarc_found, dmarc_record, domain, domain_policy = dmarc_search(from_domain);
                                   
  -- If we get here we have exactly one result in results.
  local status, ret = msys.runInPool("CPU", function()
      return dmarc_work(msg, ac, vctx, from_domain, envelope_domain, dmarc_found, dmarc_record, domain, domain_policy);
    end);

  return ret;
end

-- vim:ts=2:sw=2:et:
