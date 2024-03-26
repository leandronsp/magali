; This HTTP server works using a pool of threads.
; When a new connection is established, the client connection (clientfd) is enqueued.
; The queue uses two pointers and employs a mutex and condvar for synchronization.
; Each thread in the pool waits in the queue through a futex until a new connection is enqueued.

global _start

; Syscalls constants
%define SYS_futex 202      ; futex
%define SYS_mmap 9        ; allocate memory into heap
%define SYS_clone 56       ; create thread
%define SYS_socket 41      ; open socket
%define SYS_bind 49        ; bind to open socket
%define SYS_listen 50      ; listen to the socket
%define SYS_accept4 288    ; accept connections to the socket
%define SYS_write 1        ; write
%define SYS_read 0         ; read
%define SYS_open 2         ; open
%define SYS_close 3        ; close
%define SYS_exit 60        ; exit
%define SYS_exit_group 231 ; exit

; Misc constants
%define STDOUT 1
%define QUEUE_SIZE 10

; Socket constants
%define AF_INET 0x2
%define SOCK_STREAM 0x1    ; AF_INET + STREAM = TCP
%define SOCK_PROTOCOL 0x0
%define SIN_ZERO 0x0
%define IP_ADDRESS 0x0     ; 0.0.0.0
%define PORT 0xB80B        ; 3000 (big-endian)
%define BACKLOG 0x2

; Threading constants
%define STACK_SIZE (4096 * 1024) ; 4MB
%define PROT_READ 0x1
%define PROT_WRITE 0x2
%define MAP_GROWSDOWN 0x100
%define MAP_ANONYMOUS 0x0020     ; No file descriptor involved
%define MAP_PRIVATE 0x0002       ; Do not share across processes
%define CLONE_VM 0x00000100
%define CLONE_FS 0x00000200
%define CLONE_FILES 0x00000400
%define CLONE_SIGHAND 0x00000800
%define CLONE_PARENT 0x00008000
%define CLONE_THREAD 0x00010000
%define CLONE_IO 0x80000000
%define THREAD_FLAGS \
 CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_PARENT|CLONE_THREAD|CLONE_IO

; Futex constants
%define FUTEX_WAIT 0
%define FUTEX_WAKE 1
%define FUTEX_PRIVATE_FLAG 128

section .data
queue: dq QUEUE_SIZE dup(0) ; initialize array with zero's
front: dq 0		    ; the front pointer for connection queue
rear: dq 0		    ; the rear pointer (size) for connection queue
mutex: dq 1                 ; a shared variable to synchronize threads in spinlock
condvar: dq 0               ; a shared variable to synchronize threads in futex

section .bss
sockfd: resq 1         ; the socket file descriptor
resfd: resq 1          ; the response file descriptor
resBuf: resq 1024      ; the response buffer (reading from file)
resBufLen: equ 1024    ; the response buffer max len

section .text
listenMsg: db "Listening to the port 3000", 0xA, 0
listenMsgLen: equ $- listenMsg
; ==========================
; ======== _start ==========
; ==========================
_start:	            
   mov r8, 0           ; thread pool counter
.pool:
   mov rdi, _thandle    ; save the function pointer to be used in the thread
   call _pthread        ; create a new thread
   inc r8
   cmp r8, 5           ; pool size
   je .socket
   jmp .pool
.socket:
   ; open a new socket
   ; socket(int family, int type, int proto)
   mov rdi, AF_INET
   mov rsi, SOCK_STREAM
   mov rdx, SOCK_PROTOCOL
   mov rax, SYS_socket
   syscall
   test rax, rax
   js _error
   mov [sockfd], rax ; save the fd into memory
.bind:
   ; define the struct by pushing 12 bytes onto the stack
   ; family, port, ip_addr, sin_zero
   push dword SIN_ZERO    ; 4 bytes
   push dword IP_ADDRESS  ; 4 bytes
   push word PORT         ; 2 bytes
   push word AF_INET      ; 2 bytes

   ; bind socket to an IP address and Port
   ; bind(int fd, struct *str, int strlen)
   mov rdi, [sockfd] 
   mov rsi, rsp       ; rsp is the stack pointer, top AF_INET
   mov rdx, 16
   mov rax, SYS_bind
   syscall

   add rsp, 12        ; pop 12 bytes from the stack
   test rax, rax
   js _error
.listen:
   ; make socket to listen on the bound address
   ; listen(int fd, int backlog)
   mov rdi, [sockfd]
   mov rsi, BACKLOG
   mov rax, SYS_listen
   syscall
   test rax, rax
   js _error

   ; print "Listening on the port 3000" in STDOUT
   mov r10, listenMsg
   mov r8, listenMsgLen
   call _print
.accept:
   ; block until a new connection is established
   ; accept4(int fd, struct*, int, int)
   mov rdi, [sockfd]
   mov rsi, 0x0          
   mov rdx, 0x0
   mov r10, 0x0
   mov rax, SYS_accept4
   syscall

   mov r8, rax   ; save the client socket (rax) in the register (r8)
   call _enqueue  ; enqueue the register
   jmp .accept    ; repeat in loop


; ============================
; ======== _thandle ==========
; ============================
_thandle:
   mov eax, [rear]    ; check queue size
   cmp eax, 0         ; compare
   je .wait           ; wait while queue is empty
   call _dequeue      ; dequeue a connection (element is stored in r8)
   jmp .handle_task   ; handle the task
.wait:
   call _wait_condvar ; wait on futex controlled by an integer (condvar)
   jmp _thandle       ; repeat in loop
.handle_task:
   push r8           ; push r8 (connection) onto the stack
   call _handle       ; call the handle function
   pop rbp            ; pop connection from the stack
   jmp _thandle       ; repeat in loop

index_filename: db "index.http", 0
; ===========================
; ======== _handle ==========
; ===========================
_handle:
   push rbp               ; create a stack frame
   mov rbp, rsp           ; preserve base pointer
   mov r10, [rbp + 16]    ; 1st argument in the stack (connection)
   pop rbp                ; drop stack frame
.open_file:
   ; open HTTP/HTML file for reading
   mov rdi, index_filename
   mov rsi, 0        ; read mode
   mov rdx, 0777     ; read, write and exec by all
   mov rax, SYS_open
   syscall
   mov [resfd], rax
.read_file:
   ; read the response content from file
   mov rdi, [resfd]
   mov rsi, resBuf
   mov rdx, resBufLen
   mov rax, SYS_read
   syscall
.close_file:
   ; close response file
   mov rdi, [resfd]
   mov eax, SYS_close
   syscall
.write_client:
   ; write response into the connection socket
   mov rdi, r10
   mov rsi, resBuf
   mov rdx, resBufLen
   mov rax, SYS_write
   syscall
.close_client:
   ; close the client socket
   mov rdi, r10
   mov rax, SYS_close
   syscall
   ret

_print:
   mov rdi, STDOUT
   mov rsi, r10
   mov rdx, r8
   mov rax, SYS_write
   syscall
   ret

error: db "An error occurred", 0
errorLen: equ $- error
_error:
   mov rdi, STDOUT
   mov rsi, error
   mov rdx, errorLen
   mov rax, SYS_write
   syscall

   ; Terminates all threads
   mov rdi, 1
   mov rax, SYS_exit_group
   syscall

; ============================
; ======== _pthread ==========
; ============================
; Creates a POSIX thread using a local stack
_pthread:
   ; rdi contains the function pointer (_thandle)
   ; push the function pointer onto the stack
   push rdi

   ; memory allocation (stack-like)
   ; after syscall, 4MB will be allocated in the memory
   ; mmap(addr*, int len, int prot, int flags)
   mov rdi, 0x0
   mov rsi, STACK_SIZE
   mov rdx, PROT_WRITE | PROT_READ
   mov r10, MAP_ANONYMOUS | MAP_PRIVATE | MAP_GROWSDOWN
   mov rax, SYS_mmap
   syscall

   ; thread creation
   ; clone(int flags, thread_stack*)
   mov rdi, THREAD_FLAGS
   lea rsi, [rax + STACK_SIZE - 8]     ; stack pointer for the thread
   pop qword [rsi]
   mov rax, SYS_clone
   syscall
   ret

; ============================
; ======== _enqueue ==========
; ============================
; Enqueue connections into the queue
_enqueue:
   ; r8 register contains the connection to be enqueued

   call _lock_mutex                  ; spinlock in mutex
   mov rdi, [rear]                   ; preserve rear pointer
   mov qword [queue + rdi * 8], r8  ; enqueue the connection
   inc qword [rear]                  ; increment the rear pointer (size)
   call _emit_signal                 ; futex wake the any suspended thread
   call _unlock_mutex                ; unlock mutex
   ret

; ============================
; ======== _dequeue ==========
; ============================
; Dequeue connections from the queue
_dequeue:
   call _lock_mutex                 ; spinlock in mutex
   xor rdi, rdi                     ; clear register
   xor r8, r8                     ; clear register
   xor rdx, rdx                     ; clear register
   lea rsi, [queue]                 ; load queue address into rsi
   mov rdi, [front]                 ; current pointer
   cmp rdi, [rear]                  ; check if reached end of queue
   je .empty                        ; return if empty
   mov r8, qword [rsi + rdi * 8]   ; fetch the 1st element
.shift:
   inc rdi                               ; increment current pointer (next pointer)
   mov rdx, qword [rsi + rdi * 8]        ; save next pointer into register
   cmp rdx, 0                            ; check if reached end
   je .return                            ; return if reached end
   mov qword [rsi + (rdi - 1) * 8], rdx  ; shift the next element into the previous position
   cmp rdi, [rear]                       ; check if reached end of queue
   jle .shift                            ; repeat and keep shifting until end
.return:
   mov qword [rsi + (rdi - 1) * 8], 0    ; empty the last index after shifting
   dec qword [rear]                      ; decrement rear pointer (reduced size)
   call _unlock_mutex                    ; unlock mutex
   ret
.empty:
   mov r8, 0                            ; save into register the value 0 (none)
   call _unlock_mutex                    ; unlock mutex
   ret

; ===============================
; ======== _lock_mutex ==========
; ===============================
_lock_mutex:
   mov rax, 0
   xchg rax, [mutex]   ; atomically exchange mutex value with 0
   test rax, rax       ; test if mutex was previously unlocked
   jnz .done           ; if mutex was previously unlocked, we have successfully locked it
   pause               ; otherwise, spin and retry (reduce CPU usage)
   jmp _lock_mutex     ; keep trying to lock
.done:
   ret

; =================================
; ======== _unlock_mutex ==========
; =================================
_unlock_mutex:
   mov qword [mutex], 1  ; restore original value into mutex
   ret

; =================================
; ======== _wait_condvar ==========
; =================================
; Waits on a condition variable. 
; Uses futex syscall for underlying synchronization and thread scheduling.
_wait_condvar:
   mov rdi, condvar           ; 1st arg: the address of variable
   mov rsi, FUTEX_WAIT | FUTEX_PRIVATE_FLAG ; 2nd arg: futex op
   mov rdx, 0		      ; 3rd arg: the target value
   xor r10, r10               ; 4th arg: empty
   xor r8, r8               ; 5th arg: empty
   mov rax, SYS_futex
   syscall
   test rax, rax
   jz .done
   jmp _error
.done:
   ret

; ================================
; ======== _emit_signal ==========
; ================================
; Awake threads that are waiting on condition variable.
; Uses futex syscall for underlying synchronization and thread scheduling.
_emit_signal:
   ; 1st: uaddr* | 2nd: futex_op | 3rd: target_val | 4th: empty | 5th: empty
   mov rdi, condvar
   mov rsi, FUTEX_WAKE | FUTEX_PRIVATE_FLAG  ; the difference is in the FUTEX_WAKE flag
   mov rdx, 0
   xor r10, r10
   xor r8, r8
   mov rax, SYS_futex
   syscall
   ret
