package org.acme;

import java.util.ArrayList;
import java.util.List;

import javax.ws.rs.GET;
import javax.ws.rs.Path;
import javax.ws.rs.PathParam;
import javax.ws.rs.Produces;
import javax.ws.rs.core.MediaType;

@Path("/hello")
public class GreetingResource {

    final String hostname = System.getenv().getOrDefault("HOSTNAME", "unknown");

    private List<byte[]> bytes = new ArrayList<>();

    @GET
    @Produces(MediaType.TEXT_PLAIN)
    public String hello() {
        return "Hello World";
    }

    @GET
    @Path("/sysresources")
    @Produces(MediaType.TEXT_PLAIN)
    public String getSystemResources() {
        long memory = Runtime.getRuntime().maxMemory();
        int cores = Runtime.getRuntime().availableProcessors();
        System.out.println("/sysresources " + hostname);
        return " Memory: " + (memory / 1024 / 1024) +
                " Cores: " + cores + "\n";
    }

    @GET
    @Path("/consume/{bytes}")
    @Produces(MediaType.TEXT_PLAIN)
    public String consumeBytes(@PathParam("bytes") int bytes) {
        
        Runtime rt = Runtime.getRuntime();
        long initialFree = rt.freeMemory();
        
        this.bytes.add(new byte[bytes]);

        return "Allocated " + humanReadableByteCount(bytes, false) + " " + humanReadableByteCount(initialFree, false) + "of free " + humanReadableByteCount(rt.freeMemory(), false);

    }

    @GET
    @Path("/consume")
    @Produces(MediaType.TEXT_PLAIN)
    public String consumeSome() {
        System.out.println("/consume " + hostname);

        Runtime rt = Runtime.getRuntime();
        StringBuilder sb = new StringBuilder();
        long maxMemory = rt.maxMemory();
        long usedMemory = 0;
        // while usedMemory is less than 80% of Max
        while (((float) usedMemory / maxMemory) < 0.80) {
            sb.append(System.nanoTime() + sb.toString());
            usedMemory = rt.totalMemory();
        }
        String msg = "Allocated about 80% (" + humanReadableByteCount(usedMemory, false)
                + ") of the max allowed JVM memory size ("
                + humanReadableByteCount(maxMemory, false) + ")";
        System.out.println(msg);
        return msg + "\n";
    }

    private static String humanReadableByteCount(long bytes, boolean si) {
        int unit = si ? 1000 : 1024;
        if (bytes < unit)
            return bytes + " B";
        int exp = (int) (Math.log(bytes) / Math.log(unit));
        String pre = (si ? "kMGTPE" : "KMGTPE").charAt(exp - 1) + (si ? "" : "i");
        return String.format("%.1f %sB", bytes / Math.pow(unit, exp), pre);
    }
}