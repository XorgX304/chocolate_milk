[org  0x7c00]
[bits 16]

entry:
    ; Disable interrupts and clear direction flag
    cli
    cld

	; Set the A20 line
	in    al, 0x92
	or    al, 2
	out 0x92, al

    ; Clear DS
    xor ax, ax
    mov ds, ax

    ; Load a 32-bit GDT
    lgdt [gdt]

    ; Enable protected mode
	mov eax, cr0
	or  eax, (1 << 0)
	mov cr0, eax
    
    ; Transition to 32-bit mode by setting CS to a protected mode selector
    jmp 0x0018:pm_entry

[bits 32]

pm_entry:
    ; Set up all data selectors
    mov ax, 0x20
    mov es, ax
    mov ds, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    ; Wait for the shared early boot stack to be available for use
.wait_for_stack:
    pause
    xor  al, al
    lock xchg byte [stack_avail], al
    test al, al
    jz   short .wait_for_stack

    ; Set up a basic stack
    mov esp, 0x7c00

    cmp byte [fresh_boot], 1
    jne short .not_fresh_boot

    ; At this point, there is a fresh boot. We need to re-initialize our
    ; writable data sections

    ; Accumulate 64-bit number of boots
    add dword [boots + 0], 1
    adc dword [boots + 4], 0
    
    ; Load a pointer to the reinit memory into `ebx`
    mov ebx, reinit
.reinit_parse:
    ; If we have reached the end of the re-init sections, stop the loop
    cmp ebx, reinit_end
    je  short .not_fresh_boot

    ; memcpy(reinit_struc.vaddr, reinit_struc.payload, reinit_struc.size);
    lea esi, [ebx + reinit_struc.payload] ; Source
    mov edi, [ebx + reinit_struc.vaddr]   ; Dest
    mov ecx, [ebx + reinit_struc.size]    ; Size
    rep movsb

    ; Increment reinit pointer by the size of the payload
    add ebx, [ebx + reinit_struc.size]

    ; Increment reinit pointer by the offset of the payload in the structure
    add ebx, reinit_struc.payload

    ; Loop to the next entry
    jmp short .reinit_parse

.not_fresh_boot:
    ; Set that this is no longer a fresh boot
    mov byte [fresh_boot], 0

    ; Jump into Rust! (entry_point is a defined variable during build)
    push dword [boots + 4]
    push dword [boots + 0]
    push dword soft_reboot
    push dword bootloader_end
    call entry_point

[bits 64]

; Entry point for a soft reboot. When a soft reboot is requested, it is
; expected that the kernel has halted all other processors on the system.
; The kernel must also disable any devices which may be performing DMA or
; interrupts that it set up since the bootloader gave it execution.
; At this stage, we transition back from long mode into real mode, and jump
; right into the bootloader entry
soft_reboot:
    ; Disable interrupts
    cli

    ; We're currently running in the kernel virtual memory space. This does
    ; not have physical memory directly mapped, thus we must switch to the
    ; trampoline CR3 provided
    mov cr3, rcx

    ; Clear all GPRs. This will cause the high parts of registers to become
    ; zero, which might help with some weird transitional issues when going
    ; back to 16-bit mode
	xor rax, rax
	mov rbx, rax
	mov rcx, rax
	mov rdx, rax
	mov rsi, rax
	mov rdi, rax
	mov rbp, rax
	mov  r8, rax
	mov  r9, rax
	mov r10, rax
	mov r11, rax
	mov r12, rax
	mov r13, rax
	mov r14, rax
	mov r15, rax

    ; Load the original GDT, since the kernel has relocated the GDT into its
    ; address space
    lgdt [gdt]
    
    ; Load a stack
    mov rsp, 0x7c00

    ; Unblock NMIs
    push qword 0x0030
    push qword 0x7c00
    pushfq
    push qword 0x0028
    push qword .unblock_nmis
    iretq

.unblock_nmis:

	; Must be far dword for Intel/AMD compatibility. AMD does not support
	; 64-bit offsets in far jumps in long mode, Intel does however. Force
	; it to be 32-bit as it works in both.
	jmp far dword [reentry_longjmp]

[bits 16]

align 16
rmmode_again:
	; Disable paging
	mov eax, cr0
	btr eax, 31
	mov cr0, eax

	; Disable long mode
	mov ecx, 0xc0000080
	rdmsr
	btr eax, 8
	wrmsr

	; Load up the segments to be 16-bit segments
	mov ax, 0x10
	mov es, ax
	mov ds, ax
	mov fs, ax
	mov gs, ax
	mov ss, ax

	; Disable protected mode
	mov eax, cr0
	btr eax, 0
	mov cr0, eax

    pushfw
    push word 0
    push word .enable_nmis
    iretw

.enable_nmis:
	; Zero out all GPRs (clear out high parts for when we go into 16-bit)
	xor eax, eax
	mov ebx, eax
	mov ecx, eax
	mov edx, eax
	mov esi, eax
	mov edi, eax
	mov ebp, eax
	mov esp, 0x7c00

	; Reset the GDT and IDT to their original boot states
	lgdt [rm_gdt]
	lidt [rm_idt]
    
    ; Set up that we're in a fresh boot
    mov byte [fresh_boot], 1
    
    ; Set up that the stack is available for use
    mov byte [stack_avail], 1

	; Jump back to the start of the bootloader
	jmp 0x0000:0x7c00

align 8
reentry_longjmp:
	dd (rmmode_again - 0x7c00)
	dw 0x0008

align 8
rm_idt:
	dw 0xffff
	dq 0

align 8
rm_gdt:
	dw 0xffff
	dq 0

times 510-($-$$) db 0
dw 0xaa55

; Do not move this, it must stay at 0x7e00. We release the early boot stack
; once we get into the kernel and are using a new stack. We write directly to
; this location.
stack_avail: db 1

; Fresh boot
fresh_boot: db 1

; Number of boots such that we can track the number of boots, including soft
; reboots. This value is not reset upon a soft reboot, and thus persists.
align 8
boots: dq 0

; ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

align 8
gdt_base:
	dq 0x0000000000000000 ; 0x0000 | Null descriptor
	dq 0x00009a007c00ffff ; 0x0008 | 16-bit, present, code, base 0x7c00
	dq 0x000092000000ffff ; 0x0010 | 16-bit, present, data, base 0
	dq 0x00cf9a000000ffff ; 0x0018 | 32-bit, present, code, base 0
	dq 0x00cf92000000ffff ; 0x0020 | 32-bit, present, data, base 0
	dq 0x00209a0000000000 ; 0x0028 | 64-bit, present, code, base 0
	dq 0x0000920000000000 ; 0x0030 | 64-bit, present, data, base 0

gdt:
	dw (gdt - gdt_base) - 1
	dd gdt_base

; ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

times (0x8000 - 0x7c00)-($-$$) db 0

[bits 16]

ap_entry:
    jmp 0x0000:entry

times (0x8100 - 0x7c00)-($-$$) db 0
incbin "build/chocolate_milk.flat"

; Structure in the `reinit` vector. This structure is repeated until
; `reinit_end`
struc reinit_struc
    .vaddr:   resd 1
    .size:    resd 1
    .payload:
endstruc

; Reinit data
; Holds [vaddr: u32][size: u32][payload] to allow the bootloader to know which
; virtual addresses need to be initialized during a `fresh_boot`
reinit:
    incbin "build/chocolate_milk.reinit"
reinit_end:

; A marker for the end of the bootloader
bootloader_end:

