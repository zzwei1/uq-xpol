function dsp_upload

%WHAT:
%Listens for new files in local WR2100 DSP continaing new data files.
%Filters by scan tilt. Once a new file has been detected of the correct
%tilt, upload to s3 and send sns to sqs queue

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%load configs

%add paths
addpath('etc')
addpath('../lib')
config_input_path = 'dsp_upload.config';
temp_config_mat   = 'dsp_upload_config.mat';
location_mat      = 'last_location.mat';
path_mat          = 'last_path.mat';
tilt_mat          = 'last_tilt.mat';

%read config file
if exist(config_input_path,'file') == 2
    read_config(config_input_path,temp_config_mat);
    load(temp_config_mat);
else
    display('config file does not exist')
    return
end

%location input
if exist(location_mat,'file') == 2
	load(location_mat);
	loc_quest_out = questdlg(['Last Location Saved: ',datestr(r_dt)],'Location','Change','Use','Change');
else
	loc_quest_out = 'Change';
end
if strcmp(loc_quest_out,'Change')
    r_azi_str = inputdlg('Azimuth(deg): ');   r_azi = str2num(r_azi_str{1});
    r_lat_str = inputdlg('Latitude(deg): ');  r_lat = str2num(r_lat_str{1});
    r_lon_str = inputdlg('Longitude(deg): '); r_lon = str2num(r_lon_str{1});
    r_alt_str = inputdlg('Elevation(m): ');   r_alt = str2num(r_alt_str{1});
	r_dt      = now;
	save(location_mat,'r_azi','r_lat','r_lon','r_alt','r_dt');
elseif strcmp(loc_quest_out,'Use')
	load(location_mat);
else %no input
	disp('Location input required, aborting')
	return
end

%tilt input
if exist(tilt_mat,'file') == 2
	load(tilt_mat);
	tilt_quest_out = questdlg(['Last tilt index: ',num2str(dataset_index)],'Tilt','Change','Use','Change');
else
	tilt_quest_out = 'Change';
end
if strcmp(tilt_quest_out,'Change')
    dataset_index_str = inputdlg('Tilt number: ');
    dataset_index = str2num(dataset_index_str{1});
	save(tilt_mat,'dataset_index');
elseif strcmp(tilt_quest_out,'Use')
	load(tilt_mat);
else %no input
	disp('Tilt input required, aborting')
	return
end


%path input
if exist(path_mat,'file') == 2
	load(path_mat)
	path_quest_out = questdlg(['Last path: ',local_data_path],'Path','Change','Use','Change');
else
	path_quest_out = 'Change';
end
if strcmp(path_quest_out,'Change')
    local_data_path = inputdlg('Full Path to Local Data: '); local_data_path = local_data_path{1};
	save(path_mat,'local_data_path');
elseif strcmp(path_quest_out,'Use')
	load(path_mat);
else %no input
	disp('Path input required, aborting')
	return
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%filter local path and add to upload list to ignore old files
disp('Inital scan of input folder')
scanned_list = filter_local(local_data_path,{},dataset_index);

%start ec2
disp('Starting EC2 Machine')
cmd          = ['aws ec2 --profile personal start-instances --instance-ids ',ec2_id];
[status,out] = dos(cmd);

%create kill file
cmd = 'copy NUL upload.stop';
[status,out] = dos(cmd);

%set html to be online
cmd          = ['aws s3 cp --profile personal --acl public-read ',pwd,'/html/index_online.html ',s3_webindex_path];
[status,out] = dos(cmd);

while true
    
    %check for kill file
    if exist('upload.stop') ~=2
        break
    end

    %filter by tilts
    new_fn_list = filter_local(local_data_path,scanned_list,dataset_index);
    
    %loop through list
    for i = 1:length(new_fn_list)
        local_fn  = new_fn_list{i};
        local_ffn = [local_data_path,local_fn];
        s3_ffn    = [s3_data_path,local_fn];
        fid = fopen(local_ffn);
        if fid == -1
            continue %file open for write, not ready
        end
        
        %upload to s3
        disp(['uploading ',local_ffn,' to s3'])
        cmd          = ['aws s3 --profile personal cp ',local_ffn,' ',s3_ffn];
        [status,out] = dos(cmd);
        scanned_list  = [local_fn;scanned_list];
        
        %publish sns including s3 path, lat, lon, alt and azimuth
        disp(['sending sns for ',new_fn_list{i}])
        sns_msg      = [s3_ffn,',',num2str(r_azi),',',num2str(r_lat),',',...
            num2str(r_lon),',',num2str(r_alt)];
        cmd          = ['aws sns --profile personal publish --topic-arn ',sns_arn,' --message "',sns_msg,'"'];
        [status,out] = dos(cmd);
    end
    
    %pause for 5 seconds
    disp('pausing for 5 seconds')
    pause(5)
end

%stop ec2 machine
disp('Stopping EC2 Machine')
cmd          = ['aws ec2 --profile personal stop-instances --instance-ids ',ec2_id];
[status,out] = dos(cmd);

%set html to be offline
cmd          = ['aws s3 cp --profile personal --acl public-read ',pwd,'/html/index_offline.html ',s3_webindex_path];
[status,out] = dos(cmd);

function [new_fn_list,scanned_list] = filter_local(local_data_path,scanned_list,dataset_index)
%WHAT: for a local path, this function lists all files, filters out scn and
%rhi files, extracts dataset numbers, matches with dataset_index, then
%checks if file has already been uploaded.

%temp list
new_fn_list = {};

%list folders
listing = dir(local_data_path);
listing(1:2) = [];
if isempty(listing)
	return
else
	fn_list = {listing.name};
end

for i = 1:length(fn_list)
    %target fn
    binary_fn  = fn_list{i};

    %check if binary_ffn is in scanned_list
    out = strcmp(binary_fn,scanned_list);
    if any(out)
        continue
    end	

    %extract dataset number
    try
	    [~,tmp_name,scan_type]  = fileparts(binary_fn);
	    tmp_parts  = textscan(tmp_name,'%s','Delimiter','_'); tmp_parts = tmp_parts{1}; %split up
	    if strcmp(scan_type,{'.scn'})
			tmp_index = str2num(tmp_parts{4});    %scan number
			if tmp_index == dataset_index
				new_fn_list = [new_fn_list;binary_fn];
			end
	    end
    catch err
		display(err)
	end

    %add to scanned list
    scanned_list  = [binary_fn;scanned_list];
end
